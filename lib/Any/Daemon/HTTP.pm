use warnings;
use strict;

package Any::Daemon::HTTP;
use base 'Any::Daemon';

use Log::Report    'any-daemon-http';

use Any::Daemon::HTTP::VirtualHost ();
use Any::Daemon::HTTP::Session     ();

use HTTP::Daemon   ();
use HTTP::Status   qw/:constants :is/;
use IO::Socket     qw/SOCK_STREAM SOMAXCONN/;
use File::Basename qw/basename/;
use File::Spec     ();
use Scalar::Util   qw/blessed/;

=chapter NAME
Any::Daemon::HTTP - preforking Apache/Plack-like webserver

=chapter SYNOPSIS

  #
  # Simpelest
  #

  my $http = Any::Daemon::HTTP->new
    ( handler   => \&handler
    , host      => 'server.example.com:80'
    , %daemon_opts
    );

  sub handler($$$$$)
  {   my ($server, $client, $request, $vhost, $dir) = @_;
      return HTTP::Response->new(500);
  }

  #
  # Clean style
  #

  my $http = Any::Daemon::HTTP->new
    ( host      => 'server.example.com:80'
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
    ( host      => 'www.example.com'
    , documents => '/www/srv/example.com/http'
    , handler   => \&handler
    , %daemon_opts
    );
  $http->run;

=chapter DESCRIPTION

This module extends the basic M<Any::Daemon> with childs which handle http
connections.  This daemon does understand virtual hosts, per directory
configuration, access rules, uri rewrites, and other features of Apache
and Plack.  But you can also use it for a very simple HTTP server.

The HTTP/1.1 protocol implementation of M<HTTP::Daemon> is (ab)used.

Please support my development work by submitting bug-reports, patches
and (if available) a donation.

=section Limitations

Of course, the wishlist (of missing features) is quite long.  To list
the most important limitations of the current implementation:

=over 4
=item only one socket
You can currently only use one socket, either plain or SSL.
=item no proxy support
=back

=chapter METHODS

=c_method new OPTIONS
Also see the option descriptions of M<Any::Daemon::new()>.

When C<documents> or C<handler> is passed, then a virtual host will
be created from that.  It is nicer to create the vhost explicitly.
If you M<run()> without host or documents or any vhost definition,
then the defaults are used to create a default vhost.

=option  socket SOCKET
=default socket <created internally>

=option  use_ssl BOOLEAN
=default use_ssl <false>

=option  server_id STRING
=default server_id <program name>

=option  host HOSTNAME[:PORT]
=default host <from socket>

=option  documents DIRECTORY
=default documents C<undef>
See M<Any::Daemon::HTTP::VirtualHost::new(documents)>

=option  vhosts  VHOST|HASH-of-OPTIONS|PACKAGE|ARRAY
=default vhosts  <default>
For OPTIONS, see M<addVirtualHost()>.  Provide one or an ARRAY of
virtual host configurations, either by M<Any::Daemon::HTTP::VirtualHost>
objects or by the OPTIONS to create such objects.

=option  handler CODE|HASH
=default handler C<undef>
Equivalent to C<handlers>.

=option  handlers CODE|HASH
=default handlers C<undef>
See  M<Any::Daemon::HTTP::VirtualHost::new(handlers)>

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
=cut

sub _to_list($) { ref $_[0] eq 'ARRAY' ? @{$_[0]} : defined $_[0] ? $_[0] : () }
sub init($)
{   my ($self, $args) = @_;
    $self->SUPER::init($args);

    my $host = $args->{host};
    my ($use_ssl, $socket);
    if($socket = $args->{socket})
    {   $use_ssl = $socket->isa('IO::Socket::SSL');
        $host  ||= $socket->sockhost;
    }
    else
    {   $use_ssl = $args->{use_ssl};
        my $sock_class = $use_ssl ? 'IO::Socket::SSL' : 'IO::Socket::INET';
        eval "require $sock_class" or panic $@;

        $host or error __x"host or socket required for {pkg}::new()"
           , pkg => ref $self;

        $socket  = $sock_class->new
          ( LocalHost => $host
          , Listen    => SOMAXCONN
          , Reuse     => 1
          , Type      => SOCK_STREAM
          ) or fault "cannot create socket at $host";
    }

    my $conn_class = 'HTTP::Daemon::ClientConn';
    if($use_ssl)
    {   $conn_class .= '::SSL';
        eval "require $conn_class" or panic $@;
    }
    $self->{ADH_conn_class} = $conn_class;

    $self->{ADH_session_class}
      = $args->{session_class} || 'Any::Daemon::HTTP::Session';

    $self->{ADH_ssl}     = $use_ssl;
    $self->{ADH_socket}  = $socket;
    $self->{ADH_host}    = $host;

    $self->{ADH_vhosts}  = {};
    $self->addVirtualHost($_)
        for _to_list $args->{vhosts};

    !$args->{docroot}
        or error __x"docroot parameter has been removed in v0.11";

    $self->{ADH_server}  = $args->{server_id} || basename($0);
    $self->{ADH_headers} = $args->{standard_headers} || [];
    $self->{ADH_error}   = $args->{on_error}  || sub { $_[1] };

    # "handlers" is probably a common typo
    my $handler = $args->{handler} || $args->{handlers};
    $self->addVirtualHost
      ( name      => $host
      , aliases   => ['default']
      , documents => $args->{documents}
      , handler   => $handler
      ) if $args->{documents} || $handler;

    $self;
}

#----------------
=section Accessors
=method useSSL
=method host
=method socket
=cut

sub useSSL() {shift->{ADH_ssl}}
sub host()   {shift->{ADH_host}}
sub socket() {shift->{ADH_socket}}

#-------------
=section Virtual host administration

=method addVirtualHost VHOST|HASH-of-OPTIONS|OPTIONS

Adds a new virtual host to the knowledge of the daemon.  Can be used
at run-time, until the daemon goes into 'run' mode (starts forking
childs)  The added virtual host object is returned.

The VHOST is an already prepared VirtualHost object.  With a (HASH-of)
OPTIONS, the VirtualHost object gets created for you with those OPTIONS.
See M<Any::Daemon::HTTP::VirtualHost::new()> for OPTIONS.

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
    my $config = @_==1 ? shift : {@_};
    my $vhost;
    if(UNIVERSAL::isa($config, 'Any::Daemon::HTTP::VirtualHost'))
    {   $vhost = $config;
    }
    elsif(UNIVERSAL::isa($config, 'HASH'))
    {   $vhost = Any::Daemon::HTTP::VirtualHost->new($config);
    }
    else
    {   error __x"virtual configuration not a valid object not HASH";
    }

    info __x"adding virtual host {name}", name => $vhost->name;

    $self->{ADH_vhosts}{$_} = $vhost
        for $vhost->name, $vhost->aliases;

    $vhost;
}

=method removeVirtualHost VHOST|NAME|ALIAS
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

=method virtualHost NAME
Find the virtual host with the NAME or alias.  Returns the
M<Any::Daemon::HTTP::VirtualHost> or C<undef>.
=cut

sub virtualHost($) { $_[0]->{ADH_vhosts}{$_[1]} }

#-------------------
=section Action

=method run OPTIONS

When there is no vhost yet, one will be created.  When only one vhost
is active, you may pass C<handle_request> (see the vhost docs).

=default child_task <accept http connections>

=option  new_connection CODE
=default new_connection <undef>
The CODE is called on each new connection made.  It gets as parameters
the server (this object) and the connection (an
M<Any::Daemon::HTTP::Session> extension)

=cut

sub _connection($$)
{   my ($self, $client, $args) = @_;

    # Ugly hack, steal HTTP::Daemon's http/1.1 implementation
    bless $client, $self->{ADH_conn_class};
    ${*$client}{httpd_daemon} = $self;

    my $session = $self->{ADH_session_class}->new(client => $client);
    my $peer    = $session->get('peer');
    info __x"new client from {host} on {ip}"
       , host => $peer->{host}, ip => $peer->{ip};

    $args->{new_connection}->($self, $session);

    while(my $req  = $client->get_request)
    {   my $vhostn = $req->header('Host') || 'default';
        my $vhost  = $vhostn
            ? $self->virtualHost($vhostn) : $self->virtualHost('default');

        my $resp;
        if($vhost)
        {   $self->{ADH_current_vhost} = $vhost;
            $resp = $vhost->handleRequest($self, $session, $req);
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

        $client->send_response($resp);
    }
}

sub run(%)
{   my ($self, %args) = @_;

    $args{new_connection} ||= sub {};

    my $vhosts = $self->{ADH_vhosts};
    keys %$vhosts
        or $self->addVirtualHost
          ( name      => $self->host
          , aliases   => 'default'
          );

    # option handle_request is deprecated in 0.11
    if(my $handler = delete $args{handle_request})
    {   my (undef, $first) = %$vhosts;
        $first->addHandler('/' => $handler);
    }

    $args{child_task} ||=  sub {
        while(my $client = $self->socket->accept)
        {   $self->_connection($client, \%args);
            $client->close;
        }
        exit 0;
    };

    $self->SUPER::run(%args);
}

# HTTP::Daemon methods used by ::ClientConn.  The names are not compatible
# with MarkOv convention, so hidden for the users of this module
sub url()
{   my $self  = shift;
    my $vhost = $self->{ADH_current_vhost} or return undef;
    ($self->useSSL ? 'https' : 'http').'://'.$vhost->name;
}
sub product_tokens() {shift->{ADH_server}}

1;
