use warnings;
use strict;

package Any::Daemon::HTTP::Proxy;
use parent 'Any::Daemon::HTTP::Source';

use Log::Report    'any-daemon-http';

use LWP::UserAgent ();
use HTTP::Status   qw(HTTP_TOO_MANY_REQUESTS);
use Time::HiRes    qw(time);

=chapter NAME
Any::Daemon::HTTP::Proxy - proxy request to a remote server

=chapter SYNOPSIS

 my $proxy = Any::Daemon::HTTP::Proxy->new(path => '/forward');

 my $vh = Any::Daemon::HTTP::VirtualHost->new(proxies => $proxy);

=chapter DESCRIPTION
[Available since v0.24] B<Warning: new code, not intensively tested.>

There are two kinds of proxies:

=over 4
=item 1.
Each M<Any::Daemon::HTTP::VirtualHost> may define as many proxies as it
needs: selected by location inside a virtual host namespace, just like other
directories.  These requests are forwarded to some proxy server.

=item 2.
The HTTP daemon itself collects proxies which use C<forward_map>'s; mapping
incoming requests for (one or) many domains to (one or) many destinations.
=back

The current implementation does not support all features of proxies.
For instance, it does not combine incoming connections into new
outgoing connections.  You may take a look at M<IOMux::HTTP::Gateway>
for that.

Proxy loop detection is used by adding C<Via> header fields (which
can be removed explicitly).

=chapter METHODS

=section Constructors

=c_method new %options|\%options

A proxy has either a C<path> various, in which case it is part of
a single VirtualHost, or has a C<forward_map> when it becomes a child
of the http daemon itself.

=option  forward_map CODE|'RELAY'
=default forward_map <undef>
When there is a C<forward_map>, you can only add this proxy object to
the daemon.  The map describes how incoming domains need to be handled.

The special constant C<RELAY> will make all requests being accepted
and forwarded without uri rewrite.

=option  remote_proxy PROXY|CODE
=default remote_proxy C<undef>
When this proxy speaks to an other PROXY.  This can either be a fixed
address or name, or computed for each connection via a CODE reference.
See M<remoteProxy()>.

=option  reverse BOOLEAN
=default reverse C<true>
Enable reverse proxy behavior as well, which means that redirection
responses from the remote will be modified to have the redirected
passing through this proxy as well.

=option  user_agent M<LWP::UserAgent>
=default user_agent C<undef>

=option  strip_resp_headers NAME|REGEX|ARRAY|CODE
=default strip_resp_headers []
See M<stripHeaders()>.

=option  add_resp_headers ARRAY|CODE
=default add_resp_headers []

=option  strip_req_headers NAME|REGEX|ARRAY|CODE
=default strip_req_headers []
See M<stripHeaders()>.

=option  add_req_headers ARRAY|CODE
=default add_req_headers []

=option  change_request CODE
=default change_request C<undef>
After adding and deleting headers, you may make other changes to the
request.  The CODE is called with the proxy object, request and (rewritten)
uri as parameters.

=option  change_response CODE
=default change_response C<undef>
After adding and deleting headers, you may make other changes to the
request. The CODE is called with the proxy object, request and (rewritten)
uri as parameters.

=option  via WORD
=default via "$host:$port"
To be included in the "Via" header line, which detects proxy loops.

=option  forward_timeout SECONDS
=default forward_timeout 100

=cut

sub init($)
{   my ($self, $args) = @_;
    $self->SUPER::init($args);

    $self->{ADHDP_ua}  = $args->{user_agent}
      || LWP::UserAgent->new(keep_alive => 30);

    $self->{ADHDP_via} = $args->{via};
    if(my $fm = $args->{forward_map})
    {   $self->{ADHDP_map}   = $fm eq 'RELAY' ? sub {$_[3]} : $fm;
    }

    if(my $rem = $args->{remote_proxy})
    {   $self->{ADHDP_proxy} = ref $rem eq 'CODE' ? $rem : sub {$rem};
    }

    $self->{ADHDP_fwd_to}    = $args->{forward_timeout} // 100;

    # to be run before a request can be sent off
    my @prepare  =
      ( $self->stripHeaders($args->{strip_req_headers})
      , $self->addHeaders  ($args->{add_req_headers})
      , $args->{change_request} || ()
      );

    # to be run before a response is passed on the the client
    my @postproc =
      ( $self->stripHeaders($args->{strip_resp_headers})
      , $self->addHeaders  ($args->{add_resp_headers})
      , $args->{change_response} || ()
      );

    $self->{ADHDP_prepare}  = \@prepare;
    $self->{ADHDP_postproc} = \@postproc;
    $self;
}

#-----------------
=section Attributes

=method userAgent
=method via
=cut

sub userAgent() {shift->{ADHDP_ua}}
sub via()       {shift->{ADHDP_via}}
sub forwardMap(){shift->{ADHDP_map}}

=method remoteProxy $protocol, $session, $request, $uri
Returns a list of remote proxies (at least one) to be used for $uri.
If undef or empty, then there is direct connection to the destination.
=cut

sub remoteProxy(@)
{   my $rem = shift->{ADHDP_proxy};
    $rem ? $rem->(@_) : undef;
}

#-----------------
=section Action
=cut

my $last_used_proxy = '';
sub _collect($$$$)
{   my ($self, $vhost, $session, $req, $rel_uri) = @_;
    my $resp;

    my $vhost_name = $vhost ? $vhost->name : '';
    my $tohost = $req->header('Host') || $vhost_name;

    #XXX MO: need to support https as well
    my $uri    = URI->new_abs($rel_uri, "http://$tohost");

    # Via: RFC2616 section 14.45
    my $my_via = '1.1 ' . ($self->via // $vhost_name);
    if(my $via = $req->header('Via'))
    {   foreach (split /\,\s+/, $via)
        {   return HTTP::Response->new(HTTP_TOO_MANY_REQUESTS)
                if $_ ne $my_via;
        }
        $req->header(Via => "$via, $my_via");
    }
    else
    {   $req->push_header(Via => $my_via);
    }

    $self->$_($req, $uri)
        for @{$self->{ADHDP_prepare}};

    my $ua      = $self->userAgent;
    my @proxies = grep defined, $self->remoteProxy(HTTP => $session,$req,$uri);

    if(@proxies)
    {   $self->proxify($req, $uri);
        if($proxies[0] ne $last_used_proxy)
        {   # put last_used_proxy as first try.  UserAgent reuses connection
            @proxies = ($last_used_proxy, grep $_ ne $last_used_proxy, @proxies)
                if grep $_ eq $last_used_proxy, @proxies;
        }

        my $start   = time;
        my $timeout = 3;
        while(time - $start < $self->{ADHDP_fwd_to})
        {   my $proxy = shift @proxies;

            # redirect to next proxy
            $ua->proxy($uri->scheme, $proxy)
                if $proxy ne $last_used_proxy;

            $last_used_proxy = $proxy;
            $ua->timeout($timeout);

            my $start_req = time;
            $resp = $ua->request($req);

            info __x"request {method} {uri} via {proxy}: {status} in {t%d}ms"
              , method => $req->method, uri => "$uri", proxy => $proxy
              , status => $resp->code, t => (time-$start_req)*1000;

            last unless $resp->is_error;

            $timeout++;  # each attempt waits one second longer

            # rotate attempted proxies
            push @proxies, $proxy;
        }
    }
    else
    {   $ua->proxy($uri->scheme, undef);
        $last_used_proxy = '';

        $ua->timeout(180);
        $resp = $ua->request($req);
        info __x"request {method} {uri} without proxy: {status}"
          , method => $req->method, uri => "$uri", status => $resp->code;
    }

    $self->$_($resp, $uri)
        for @{$self->{ADHDP_postproc}};

    $resp;
}

=method stripHeaders $message, $name|Regexp|ARRAY|CODE|LIST
Convert a specification about which headers should be stripped into
a singled CODE reference to remove the specified fields from a request
(to a proxy) or response (by the proxy).

   strip_req_headers => 'ETag'
   strip_req_headers => qr/^X-/
   strip_req_headers => [ 'ETag', qr/^X-/ ]
   
   strip_req_headers => sub { my ($proxy,$msg,$uri) = @_; ... }

=cut

sub stripHeaders(@)
{   my $self = shift;
    my @strip;
    foreach my $field (@_ > 1 ? @_ : ref $_[0] eq 'ARRAY' ? @{$_[0]} : shift)
    {   push @strip
          , !ref $field           ? sub {$_[0]->remove_header($field)}
          : ref $field eq 'CODE'  ? $field
          : ref $field eq 'Regex' ? sub {
                my @kill = grep $_ =~ $field, $_[0]->header_field_names;
                $_[0]->remove_header($_) for @kill;
            }
          : panic "do not understand $field";
    }

    @strip or return;
    sub { my $header = $_[1]->headers; $_->($header) for @strip };
}

=method addHeaders $message, PAIRS|ARRAY|CODE
Add header lines to the request or response $message.  Existing headers
with the same name are retained.

   add_req_headers   => [ Server => 'MSIE' ]
   add_req_headers   => sub { my ($proxy,$msg,$uri) = @_; ... }

=cut

sub addHeaders($@)
{   my $self  = shift;
    return if @_==1 && ref $_[0] eq 'CODE';

    my @pairs = @_ > 1 ? @_ : defined $_[0] ? @{$_[0]} : ();
    @pairs or return sub {};

    sub { $_[1]->push_header(@pairs) };
}

=method proxify $request, $uri
The $uri is the result of a rewrite of the destination mentioned in the
$request.  To be able to forward the $request to the next server, we need
to rewrite its headers.

It is also possible the the original request originates from browser
which is not configured for proxying.  That will be repared as well.
=cut

sub proxify($$)
{   my ($self, $request, $uri) = @_;
    $request->uri($uri);
    $request->header(Host => $uri->authority);
}

=method forwardRewrite $session, $request, $uri
=cut

sub forwardRewrite($$$)
{   my ($self, $session, $req, $uri) = @_;
    $self->allow($session, $req, $uri) or return;
    my $mapper = $self->forwardMap     or return;
    $mapper->(@_);
}

=method forwardRequest $session, $request, $uri
=cut

sub forwardRequest($$$)
{   my ($self, $session, $req, $uri) = @_;
    $self->_collect(undef, $session, $req, $uri);
}

#----------------
=chapter DETAILS

=section Using the proxy-map

The proxy map will only be used when the access rules permit the client
to access this source.  When the map returns a new URI as result, that
will be the new destination of the request.  When C<undef> is returned,
there may be an other proxy specification which will accept it.

A typical usage could be:

  Any::Daemon::HTTP::Proxy->new(forward_map => \&mapper);

  sub mapper($$$)
  {   my ($proxy, $session, $request, $uri) = @_;

      if(lc $uri->authority eq 'my.example.com')
      {   my $new = $uri->clone;
          $new->authority('somewhere.else.org');
          return $new;
      }

      undef;
  }

You can do anything you need: build lookup tables, rewrite parameter
lists, and more.  However: the final URI needs to be an absolute URI.
Please create regression tests for your mapper function.

=section Proxy to a proxy

An open forwarding proxy can be made with

  Any::Daemon::HTTP::Proxy->new
    ( forward_map  => 'RELAY'
    , remote_proxy => 'proxy.firewall.me'
    );

=cut 

1;
