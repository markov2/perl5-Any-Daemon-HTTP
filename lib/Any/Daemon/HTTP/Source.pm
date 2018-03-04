# This code is part of distribution Any-Daemon-HTTP. Meta-POD processed
# with OODoc into POD and HTML manual-pages.  See README.md
# Copyright Mark Overmeer.  Licensed under the same terms as Perl itself.

package Any::Daemon::HTTP::Source;

use warnings;
use strict;

use Log::Report    'any-daemon-http';

use Net::CIDR      qw/cidrlookup/;
use List::Util     qw/first/;
use HTTP::Status   qw/HTTP_FORBIDDEN/;

sub _allow_cleanup($);
sub _allow_match($$$$);

=chapter NAME
Any::Daemon::HTTP::Source - source of information

=chapter SYNOPSIS

=chapter DESCRIPTION
Each M<Any::Daemon::HTTP::VirtualHost> will define where the files
are located.  Parts of the URI path can map on different (virtual)
resources, with different access rights.

=over 4

=item *

Directories containing files are handled by M<Any::Daemon::HTTP::Directory>
objects.

=item *

User directories, like used in the URI C<<http://xx/~user/yy>> are
implemented in M<Any::Daemon::HTTP::UserDirs>, which extends this class.

=item *

Forwarding proxies translate a path into requests to a remote server.
The reply is returned.  Various rules can be applied.  Implemented in
M<Any::Daemon::HTTP::Proxy>.

=back

=chapter METHODS

=section Constructors

=c_method new %options|\%options

=option   path PATH
=default  path '/'
If the directory PATH (relative to the document root C<location>) is not
trailed by a '/', it will be made so.

=option   allow   CIDR|HOSTNAME|DOMAIN|CODE|ARRAY
=default  allow   <undef>
Allow all requests which pass any of these parameters, and none
of the deny parameters.  See L</Allow access>.  B<Be warned> that
the access rights are not inherited from directory configurations
encapsulating this one.

=option   deny    CIDR|HOSTNAME|DOMAIN|CODE|ARRAY
=default  deny    <undef>
See C<allow> and L</Allow access>

=option   name    STRING
=default  name    C<path>
=cut

sub new(@)
{   my $class = shift;
    my $args  = @_==1 ? shift : +{@_};
    (bless {}, $class)->init($args);
}

sub init($)
{   my ($self, $args) = @_;

    my $path = $self->{ADHS_path}  = $args->{path} || '/';
    $self->{ADHS_allow} = _allow_cleanup $args->{allow};
    $self->{ADHS_deny}  = _allow_cleanup $args->{deny};
    $self->{ADHS_name}  = $args->{name} || $path;
    $self;
}

#-----------------
=section Attributes
=method path
=method name
=cut

sub path()     {shift->{ADHS_path}}
sub name()     {shift->{ADHS_name}}

#-----------------
=section Permissions

=method allow $session, $request, $uri
BE WARNED that the $uri is the rewrite of the $request uri, and therefore
you should use that $uri.  The $session represents a user.

See L</Allow access>.
=cut

sub allow($$$$)
{   my ($self, $session, $req, $uri) = @_;
    if(my $allow = $self->{ADHS_allow})
    {   $self->_allow_match($session, $uri, $allow) or return 0;
    }
    if(my $deny = $self->{ADHS_deny})
    {    $self->_allow_match($session, $uri, $deny) and return 0;
    }
    1;
}

sub _allow_match($$$$)
{   my ($self, $session, $uri, $rules) = @_;
    my $peer = $session->get('peer');
    first { $_->($peer->{ip}, $peer->{host}, $session, $uri) } @$rules;
}

sub _allow_cleanup($)
{   my $p = shift or return;
    my @p;
    foreach my $r (ref $p eq 'ARRAY' ? @$p : $p)
    {   push @p
          , ref $r eq 'CODE'      ? $r
          : index($r, ':') >= 0   ? sub {cidrlookup $_[0], $r}    # IPv6
          : $r !~ m/[a-zA-Z]/     ? sub {cidrlookup $_[0], $r}    # IPv4
          : substr($r,0,1) eq '.' ? sub {$_[1] =~ qr/(^|\.)\Q$r\E$/i} # Domain
          :                         sub {lc($_[1]) eq lc($r)}     # hostname
    }
    @p ? \@p : undef;
}

=method collect $vhost, $session, $request, $uri
Try to produce a response (M<HTTP::Response>) for something inside this
directory structure.  C<undef> is returned if nothing useful is found.
=cut

sub collect($$$$)
{   my ($self, $vhost, $session, $req, $uri) = @_;

    $self->allow($session, $req, $uri)
        or return HTTP::Response->new(HTTP_FORBIDDEN);

    $self->_collect($vhost, $session, $req, $uri);
}

sub _collect($$$) { panic "must be extended" }

#-----------------------
=section Actions
=cut

#-----------------------
=chapter DETAILS

=section Resource restrictions

=subsection Allow access

The M<allow()> method handles access rights.  When a trueth value is
produced, then access is permitted.

The base class implements access rules via the C<allow> or C<deny> option
of M<new()>.  These parameters are exclusive (which is slightly different
from Apache); you can either allow or deny, but not both at the same time.
B<Be warned> that the access rights are also not inherited from directory
configurations encapsulating this one.

The parameters to C<allow> or C<deny> are an ARRAY with any combination of
=over 4
=item IPv4 and IPv6 address ranges in CIDR notation
=item hostname
=item domain name (leading dot)
=item your own CODE reference, which will be called with the IP address,
  the hostname, the session, and the rewritten URI.
=back

=example new(allow) parameters
 my $vhost = My::VHOST::Class->new( allow =>
    [ '192.168.2.1/32         # IPv4 CIDR, single address
    , '10/8'                  # IPv4 CIDR
    , '10.0.0.0-10.3.255.255' # IPv4 range
    , '::dead:beef:0:0/110'   # IPv6 range
    , 'www.example.com'       # hostname
    , '.example.com'          # domain and subdomains
    , 'example.com'           # only this domain
    ], ...

=example create own access rules
If you have an ::VirtualHost extension class, you do this:

 sub allow($$$)
 {   my ($self, $session, $request, $uri) = @_;

     # General rules may refuse access already
     $self->SUPER::allow($session, $request, $uri)
         or return 0;

     # here your own checks
     # $session is a Any::Daemon::HTTP::Session
     # $request is a HTTP::Request
     # $uri     is a URI::

     1;
 }

You may also pass a code-ref to M<new(allow)>:

 my $vhost = Any::Daemon::HTTP::VirtualHost
     ->new(allow => \&my_rules, ...);

 sub my_rules($$$$)   # called before each request
 {   my ($ip, $host, $session, $uri) = @_;
     # return true if access is permitted
 }

=cut

1;
