# This code is part of distribution Any-Daemon-HTTP. Meta-POD processed
# with OODoc into POD and HTML manual-pages.  See README.md
# Copyright Mark Overmeer.  Licensed under the same terms as Perl itself.

package Any::Daemon::HTTP;
use base 'Any::Daemon';

use warnings;
use strict;

use Log::Report      'any-daemon-http';

use Any::Daemon::HTTP::VirtualHost ();
use Any::Daemon::HTTP::Session     ();
use Any::Daemon::HTTP::Proxy       ();

use HTTP::Daemon     ();
use HTTP::Status     qw/:constants :is/;
use IO::Socket       qw/SOCK_STREAM SOMAXCONN SOL_SOCKET SO_LINGER/;
use IO::Socket::IP   ();
use IO::Select       ();
use File::Basename   qw/basename/;
use File::Spec       ();
use Scalar::Util     qw/blessed/;
use Errno            qw/EADDRINUSE/;

use constant
  { PROTO_HTTP  => 80
  , PROTO_HTTPS => 443
  };

# To support IPv6, replace ::INET by ::IP
@HTTP::Daemon::ClientConn::ISA = qw(IO::Socket::IP);

=chapter NAME
Any::Daemon::HTTP - preforking Apache/Plack-like webserver

=chapter SYNOPSIS

  #
  # Simpelest
  #

  use Log::Report;
  use Any::Daemon::HTTP;
  my $http = Any::Daemon::HTTP->new
    ( handler   => \&handler
    , listen    => 'server.example.com:80'
    , %daemon_opts
    );

  sub handler($$$$$)
  {   my ($server, $client, $request, $vhost, $dir) = @_;
      return HTTP::Response->new(500);
  }

  #
  # Clean style
  #

  use Log::Report;
  use Any::Daemon::HTTP;
  my $http = Any::Daemon::HTTP->new
    ( listen    => 'server.example.com:80'
    );

  $http->addVirtualHost
    ( name      => 'www.example.com'
    , aliases   => 'example.com'
    , documents => '/www/srv/example.com/http'
    , handler   => \&handler
    );

  $http->run;

  #
  # Limited server
  #

  my $http = Any::Daemon::HTTP->new
    ( listen    => 'www.example.com'
    , documents => '/www/srv/example.com/http'
    , handler   => \&handler
    , %daemon_opts
    );
  $http->run;

=chapter DESCRIPTION

This module extends the basic M<Any::Daemon> with childs which handle http
connections.  This daemon does understand virtual hosts, per directory
configuration, access rules, uri rewrites, proxies, and other features of
Apache and Plack.  But you can also use it for a very simple HTTP server.

The HTTP/1.1 protocol implementation of M<HTTP::Daemon> is (ab)used.
See L</DETAILS> for a list of features and limitations.

Please support my development work by submitting bug-reports, patches
and (if available) a donation.

=chapter METHODS

=c_method new %options
Also see the option descriptions of M<Any::Daemon::new()>.

When C<documents> or C<handler> is passed, then a virtual host will
be created from that.  It is nicer to create the vhost explicitly.
If you M<run()> without host or documents or any vhost definition,
then the defaults are used to create a default vhost.

=requires listen SOCKET|HOSTNAME[:PORT]|IPADDR[:PORT]|ARRAY
Specifies one or more SOCKETs, HOSTNAMEs, or IP-ADDResses where connections
can come in.  Old option names C<host> and C<socket> are also still
available.

=option  server_id STRING
=default server_id <program name>

=option  documents DIRECTORY
=default documents C<undef>
See M<Any::Daemon::HTTP::VirtualHost::new(documents)>.

=option  vhosts  VHOST|PACKAGE|\%options|ARRAY
=default vhosts  <default>
The %options are passed to M<addVirtualHost()>, to create a virtual host
object under fly.  You may also pass an initialized
M<Any::Daemon::HTTP::VirtualHost> object, or a PACKAGE name to be used
for the default vhost.  An ARRAY contains a mixture of vhost definitions.
[0.24] Same as option C<vhost>.

=option  proxies  PROXY|PACKAGE|\%options|ARRAY
=default proxies  <default>
[0.24] For %options, see M<addProxy()>.
The %options are passed to M<addProxy()>, to create a proxy
object under fly.  You may also pass an M<Any::Daemon::HTTP::Proxy>
objects or by the %options to create such objects.  An ARRAY contains a
mixture of proxy definitions.  Same as option C<proxy>.

=option  handlers CODE|HASH
=default handlers C<undef>
See  M<Any::Daemon::HTTP::VirtualHost::new(handlers)>. You can also use
the option name C<handler>.

=option  standard_headers ARRAY
=default standard_headers C<[ ]>
Pass a list of key-value pairs which will be added to each produced
response.  They are fed into M<HTTP::Headers::push_header()>.

=option  on_error CODE
=default on_error C<undef>
[0.21] This handler is called when an 4xx or 5xx error response has
been produced.  The result of this function should be the new response
(may be the same as the incoming)

=option  session_class PACKAGE
=default session_class M<Any::Daemon::HTTP::Session>
[0.21] The PACKAGE must extend the default class.  The extended class may
be used to implement loading and saving session information, or adding
abstraction.

=option  vhost_class PACKAGE
=default vhost_class M<Any::Daemon::HTTP::VirtualHost>
[0.22] The PACKAGE must extend the default class.  See the
L<Any::Daemon::HTTP::VirtualHost/DETAILS> about creating your own virtual
hosts.

=option  proxy_class PACKAGE
=default proxy_class M<Any::Daemon::HTTP::Proxy>
[0.24] The PACKAGE must extend the default class.

=cut

sub _to_list($) { ref $_[0] eq 'ARRAY' ? @{$_[0]} : defined $_[0] ? $_[0] : () }
sub init($)
{   my ($self, $args) = @_;
    $self->SUPER::init($args);

    my (@sockets, @hosts);
    foreach (@{$args}{qw/listen socket host/} )
    {   foreach my $conn (ref $_ eq 'ARRAY' ? @$_ : $_)
        {   my ($socket, @host) = $self->_create_socket($conn);
            push @sockets, $socket if $socket;
            push @hosts, @host;
        }
    }

    @sockets or error __x"host or socket required for {pkg}::new()"
      , pkg => ref $self;

    $self->{ADH_sockets} = \@sockets;
    $self->{ADH_hosts}   = \@hosts;

    $self->{ADH_session_class}
      = $args->{session_class} || 'Any::Daemon::HTTP::Session';
    $self->{ADH_vhost_class}
      = $args->{vhost_class}   || 'Any::Daemon::HTTP::VirtualHost';
    $self->{ADH_proxy_class}
      = $args->{proxy_class}   || 'Any::Daemon::HTTP::Proxy';

    $self->{ADH_vhosts}  = {};
    $self->addVirtualHost($_) for _to_list($args->{vhosts}  || $args->{vhost});

    $self->{ADH_proxies} = [];
    $self->addProxy($_)       for _to_list($args->{proxies} || $args->{proxy});

    !$args->{docroot}
        or error __x"docroot parameter has been removed in v0.11";

    $self->{ADH_server}  = $args->{server_id} || basename($0);
    $self->{ADH_headers} = $args->{standard_headers} || [];
    $self->{ADH_error}   = $args->{on_error}  || sub { $_[1] };

    # "handlers" is probably a common typo
    my $handler = $args->{handlers} || $args->{handler};

    my $host      = shift @hosts;
    $self->addVirtualHost
      ( name      => $host
      , aliases   => [@hosts, 'default']
      , documents => $args->{documents}
      , handler   => $handler
      ) if $args->{documents} || $handler;

    $self;
}

sub _create_socket($)
{   my ($self, $listen) = @_;
    defined $listen or return;

    return ($listen, $listen->sockhost.':'.$listen->sockport)
        if blessed $listen && $listen->isa('IO::Socket');

    my $port = $listen =~ s/\:([0-9]+)$// ? $1 : PROTO_HTTP;
    my $host = $listen;
    
    my $sock_class;
    if($port==PROTO_HTTPS)
    {   $sock_class = 'IO::Socket::SSL';
        eval "require IO::Socket::SSL; require HTTP::Daemon::ClientConn::SSL;"
            or panic $@;
    }
    else
    {   $sock_class = 'IO::Socket::IP';
    }

    # Wait max 60 seconds to get the socket
    # You should be able to reduce the time to wait by setting linger
    # on the socket in the process which has opened the socket before.
    my ($socket, $elapse);
    foreach my $retry (1..60)
    {   $elapse = $retry -1;

        $socket = $sock_class->new
          ( LocalHost => $host
          , LocalPort => $port
          , Listen    => SOMAXCONN
          , Reuse     => 1
          , Type      => SOCK_STREAM
          , Proto     => 'tcp'
          );

        last if $socket || $! != EADDRINUSE;

        notice __x"waiting for socket at {address} to become available"
          , address => "$host:$port"
            if $retry==1;

        sleep 1;
    }

    $socket
        or fault __x"cannot create socket at {address}"
             , address => "$host:$port";

    notice __x"got socket after {secs} seconds", secs => $elapse
        if $elapse;

    ($socket, "$listen:$port", $socket->sockhost.':'.$socket->sockport);
}

#----------------
=section Accessors
=method sockets
Returns all the sockets we listen on.  This list is the result of
M<new(listen)>.
=cut

sub sockets() {@{shift->{ADH_sockets}}}
sub hosts()   {@{shift->{ADH_hosts}}}

#-------------
=section Host administration

VirtualHosts and a global proxy can be added in a any order.  They
can also be added at run-time!

When a request arrives, it contains a C<Host> header which is used to
select the right object.  When a VirtualHost has this name or alias,
that will be address.  Otherwise, if there are global proxy objects,
they are tried one after the other to see whether the forwardRewrite()
reports that it accepts the request.  If this all fails, then the request
is redirected to the host named (or aliased) 'default'.  As last resort,
you get an error.

=method addVirtualHost $vhost|\%options|%options

Adds a new virtual host to the knowledge of the daemon.  Can be used
at run-time, until the daemon goes into 'run' mode (starts forking
childs)  The added virtual host object is returned.

The $vhost is an already prepared VirtualHost object.  With %options,
the VirtualHost object gets created for you with those %options.
See M<Any::Daemon::HTTP::VirtualHost::new()> for %options.

See the manual page for M<Any::Daemon::HTTP::VirtualHost> on how you
can cleanly extend the class for your own purpose.

=examples

  # Simple version
  $http->addVirtualHost
    ( name      => 'images'
    , aliases   => 'images.example.com'
    , documents => '/home/www/images
    );

  # Own virtual host, usually in separate pm-file
  { package My::VHost;
    use parent 'Any::Daemon::HTTP::VirtualHost';
    ...
  }
  my $vhost = My::VHost->new(...);
  $http->addVirtualHost($vhost);

  # Implicitly add virtual hosts
  push @vhosts, $vhost;
  my $http = Any::Daemon::HTTP->new
    ( ...
    , vhosts    => \@vhosts
    );
=cut

sub addVirtualHost(@)
{   my $self   = shift;
    my $config = @_ > 1 ? +{@_} : !defined $_[0] ? return : shift;

    my $vhost;
    if(blessed $config && $config->isa('Any::Daemon::HTTP::VirtualHost'))
         { $vhost = $config }
    elsif(ref $config eq 'HASH')
         { $vhost = $self->{ADH_vhost_class}->new($config) }
    else { error __x"virtual host configuration not a valid object nor HASH" }

    info __x"adding virtual host {name}", name => $vhost->name;

    $self->{ADH_vhosts}{$_} = $vhost
        for $vhost->name, $vhost->aliases;

    $vhost;
}

=method addProxy $object|\%options|%options
Add a M<Any::Daemon::HTTP::Proxy> object which has a C<proxy_map>,
about how to handle requests for incoming hosts.  The proxy settings
will be tried in order of addition, only when there are no virtual
hosts addressed.
=cut

sub addProxy(@)
{   my $self   = shift;
    my $config = @_ > 1 ? +{@_} : !defined $_[0] ? return : shift;
    my $proxy;
    if(UNIVERSAL::isa($config, 'Any::Daemon::HTTP::Proxy'))
         { $proxy = $config }
    elsif(UNIVERSAL::isa($config, 'HASH'))
         { $proxy = $self->{ADH_proxy_class}->new($config) }
    else { error __x"proxy configuration not a valid object nor HASH" }

    $proxy->forwardMap
        or error __x"proxy {name} has no map, so needs inside vhost"
             , name => $proxy->name;

    info __x"adding proxy {name}", name => $proxy->name;

    push @{$self->{ADH_proxies}}, $proxy;
}

=method removeVirtualHost $vhost|$name|$alias
Remove all name and alias registrations for the indicated virtual host.
Silently ignores non-existing vhosts.  The removed virtual host object
is returned.
=cut

sub removeVirtualHost($)
{   my ($self, $id) = @_;
    my $vhost = blessed $id && $id->isa('Any::Daemon::HTTP::VirtualHost')
       ? $id : $self->virtualHost($id);
    defined $vhost or return;

    delete $self->{ADH_vhosts}{$_}
        for $vhost->name, $vhost->aliases;
    $vhost;
}

=method virtualHost $name
Find the virtual host with the $name or alias.  Returns the
M<Any::Daemon::HTTP::VirtualHost> or C<undef>.
=cut

sub virtualHost($) { $_[0]->{ADH_vhosts}{$_[1]} }

=method proxies
[0.24] Returns a list with all added proxy objects.
=cut

sub proxies() { @{shift->{ADH_proxies}} }

=method findProxy $session, $request, $host
[0.24] Find the first proxy which is mapping the URI of the $request.  Returns a
pair, containing the proxy and the location where it points to.

Usually, in a proxy, the request needs to be in absolute form in the
request header.  However, we can be more 
=cut

sub findProxy($$$)
{   my ($self, $session, $req, $host) = @_;
    my $uri = $req->uri->abs("http://$host");
    foreach my $proxy ($self->proxies)
    {   my $mapped = $proxy->forwardRewrite($session, $req, $uri) or next;
        return ($proxy, $mapped);
    }

    ();
}

#-------------------
=section Action

=method run %options

When there is no vhost yet, one will be created.  When only one vhost
is active, you may pass C<handle_request> (see the vhost docs).

=default child_task <accept http connections>

=option  new_connection CODE|$method
=default new_connection 'newConnection'
The CODE is called on each new connection made.  It gets as parameters
the server (this object) and the connection (an
M<Any::Daemon::HTTP::Session> extension)

=option  max_conn_per_child INTEGER
=default max_conn_per_child 10_000
[0.24] Average maximum number of connections which are handled
per process, before it commits suicide to cleanup garbaged memory.
The parent will start a new process.

This value gets a random value in 10% range added to subtracted to avoid
that all childs reset at the same time.  So, for the default value, 9_000
upto 11_000 connections will be served before a reset.

=option  max_req_per_conn  INTEGER
=default max_req_per_conn  100
[0.24] maximum number of HTTP requests handled in one connection.

=option  max_req_per_child INTEGER
=default max_req_per_child 100_000
[0.24] maximum number of HTTP requests accepted by all connections for
one process.

=option  max_time_per_conn SECONDS
=default max_time_per_conn 120
Maximum time a connection will stay alive.  When the time expires, the
process will forcefully killed.  For each request, C<req_time_bonus>
seconds are added.  This may be a bit short when your files are large.

=option  req_time_bonus SECONDS
=default req_time_bonus 5

=option  linger SECONDS
=default linger C<undef>
When defined, it sets the maximim time a client may stay connected
to collect the data after the connection is closed by the server.
When zero, the last response may get lost, because the connection gets
reset immediately.  Without linger, browsers may block the server
resource for a long time.  So, a linger of a few seconds (when you only
have small files) will help protecting your server.

This setting determines the minimum time for a save server reboot.  When
the daemon is stopped, the client may still keeps its socket.  The restart
of the server may fail with "socket already in use".
=cut

sub _connection($$)
{   my ($self, $client, $args) = @_;
    my $nr_req   = 0;
    my $max_req  = $args->{max_req_per_conn} || 100;
    my $start    = time;
    my $deadline = $start + ($args->{max_time_per_conn} || 120);
    my $bonus    = $args->{req_time_bonus} // 2;

    my $conn_class = $client->isa('IO::Socket::SSL')
      ? 'HTTP::Daemon::ClientConn::SSL' : 'HTTP::Daemon::ClientConn';

    # Ugly hack, steal HTTP::Daemon's http/1.1 implementation
    bless $client, $conn_class;
    ${*$client}{httpd_daemon} = $self;

    my $session = $self->{ADH_session_class}->new(client => $client);
    my $peer    = $session->get('peer');
    my $host    = $peer->{host};
    my $ip      = $peer->{ip};
    info __x"new client from {host} on {ip}", host => $host, ip => $ip;

    # Change title in ps-table
    my $title = $0;
    $title    =~ s/ .*//;
    $title   .= ' http from '. ($host||$ip);
    $0        = $title;

	my $init_conn = $args->{new_connection};
	if(ref $init_conn eq 'CODE') { $init_conn->($self, $session) }
	else { $self->$init_conn($session) }

    $SIG{ALRM} = sub {
        notice __x"connection from {host} lasted too long, killed after {time%d} seconds"
          , host => $host, time => $deadline - $start;
        exit 0;
    };

    alarm $deadline - time;
    while(my $req  = $client->get_request)
    {   my $vhostn = $req->header('Host') || 'default';
        my $resp;

        if(my $vhost  = $self->virtualHost($vhostn))
        {   $self->{ADH_host_base}
              = (ref($client) =~ /SSL/ ? 'https' : 'http').'://'.$vhost->name;
            $resp = $vhost->handleRequest($self, $session, $req);
        }
        elsif(my ($proxy, $where) = $self->findProxy($session, $req, $vhostn))
        {   $resp = $proxy->forwardRequest($session, $req, $where);
        }
        elsif(my $default = $self->virtualHost('default'))
        {   $resp = HTTP::Response->new(HTTP_TEMPORARY_REDIRECT);
            $resp->header(Location => 'http://'.$default->name);
        }
        else
        {   $resp = HTTP::Response->new(HTTP_NOT_ACCEPTABLE,
               "virtual host $vhostn is not available");
        }

        unless($resp)
        {   notice __x"no response produced for {uri}", uri => $req->uri;
            $resp = HTTP::Response->new(HTTP_SERVICE_UNAVAILABLE);
        }

        $resp->push_header(@{$self->{ADH_headers}});
        $resp->request($req);

        # No content, then produce something better than an empty page.
        if(is_error($resp->code))
        {   $resp = $self->{ADH_error}->($self, $resp, $session, $req);
            $resp->content or $resp->content($resp->status_line);
        }
        $deadline += $bonus;
        alarm $deadline - time;

        my $close = $nr_req++ >= $max_req;

        $resp->header(Connection => ($close ? 'close' : 'open'));
        $client->send_response($resp);

        last if $close;
    }

    alarm 0;
    $nr_req;
}

sub run(%)
{   my ($self, %args) = @_;

    $args{new_connection} ||= 'newConnection';

    my $vhosts = $self->{ADH_vhosts};
    unless(keys %$vhosts)
    {   my ($host, @aliases) = $self->hosts;
        $self->addVirtualHost(name => $host, aliases => ['default', @aliases]);
    }

    # option handle_request is deprecated in 0.11
    if(my $handler = delete $args{handle_request})
    {   my (undef, $first) = %$vhosts;
        $first->addHandler('/' => $handler);
    }

    my $title      = $0;
    $title         =~ s/ .*//;
    my ($req_count, $conn_count) = (0, 0);
    my $max_conn   = $args{max_conn_per_child} || 10_000;
    $max_conn      = int(0.9 * $max_conn + rand(0.2 * $max_conn))
        if $max_conn > 10;

    my $max_req    = $args{max_req_per_child}  || 100_000;
    my $linger     = $args{linger};

    $0 = "$title, manager";  # $0 visible with 'ps' command
    $args{child_task} ||= sub {
        $0 = "$title, not used yet";
        # even with one port, we still select...
        my $select = IO::Select->new($self->sockets);

      CONNECTION:
        while(my @ready = $select->can_read)
        {
            foreach my $socket (@ready)
            {   my $client = $socket->accept or next;
                $client->sockopt(SO_LINGER, (pack "II", 1, $linger))
                    if defined $linger;

                $0 = "$title, handling "
                   . $client->peerhost.":".$client->peerport . " at "
                   . $client->sockhost.':'.$client->sockport;

                $req_count += $self->_connection($client, \%args);
                $client->close;

                last CONNECTION
                    if $conn_count++ >= $max_conn
                    || $req_count    >= $max_req;
            }
            $0 = "$title, idle after $conn_count";
        }
        0;
    };

    $self->SUPER::run(%args);
}

=method newConnection $session
Called by default when a new client has been accepted.
See M<run(new_connection)>.
=cut

sub newConnection($)
{   my ($self, $session) = @_;
    return $self;
}

# HTTP::Daemon methods used by ::ClientConn.  We steal that parent role,
# but need to mimic the object a little.  The names are not compatible
# with MarkOv's convention, so hidden for the users of this module
sub url() { shift->{ADH_host_base} }
sub product_tokens() {shift->{ADH_server}}

1;

__END__
=chapter DETAILS

=section Server supported features
Many often used features are supported

=over 4
=item * HTTP/1.1 protocol
Supported by via the M<HTTP::Daemon> connection implementation, which
is gracefully hijacked.  Messages are M<HTTP::Request> and M<HTTP::Response>
objects, borrowed from LWP.

=item * virtual hosts
Multiple "hosts" listening on the same port, abstracted in
M<Any::Daemon::HTTP::VirtualHost> objects.  The vhosts have a
name and may have a number of aliases.

=item * directories per VirtualHost 
One or more "directory" configurations may be added, which may be
nested.  They are represened by a M<Any::Daemon::HTTP::Directory> objects.
Each "directory" maps a "path" in the request to a directory on disk.  

=item * allow/deny per Directory
Supports CIDR and hostname based access restrictions.

=item * directory lists per Directory
When permitted and no C<index.html> file is found, a listing is generated.

=item * user directories per VirtualHost 
One directory object can be a M<Any::Daemon::HTTP::UserDirs>, managing
user directories (request paths which start with C</~$username>)

=item * proxies

=item * static content caching
Reduce retransmitting files, supporting C<ETag> and C<Last-Modified>.

=item * rewrite rules per VirtualHost
Translate incoming request paths into new paths in the same vhost.

=item * redirection rules per VirtualHost
Translate incoming request paths into browser redirects.

=item * dynamic content handlers per VirtualHost
When there is no matching file, a handler will be called to produce the
required information.  The default handler will produce 404 errors.

=item * dynamic content caching
Reduce transmitting dynamic content using C<ETag> and C<MD5>'s

=back

=section Server limitations

Ehhh...

=cut
