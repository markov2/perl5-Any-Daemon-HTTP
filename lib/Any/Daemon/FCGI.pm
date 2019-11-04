# This code is part of distribution Any-Daemon-HTTP. Meta-POD processed
# with OODoc into POD and HTML manual-pages.  See README.md
# Copyright Mark Overmeer.  Licensed under the same terms as Perl itself.

package Any::Daemon::FCGI;
use parent 'IO::Socket::IP';

use warnings;
use strict;

use Log::Report      'any-daemon-http';

use Any::Daemon::FCGI::ClientConn ();

=chapter NAME
Any::Daemon::FCGI - serve the FCGI protocol

=chapter SYNOPSIS

  use Any::Daemon::HTTP 0.29;
  my $http = Any::Daemon::HTTP->new
    ( listen    => 'www.example.com'
    , protocol  => 'FCGI'
    , ...
    );

=chapter DESCRIPTION
The Fast CGI protocol connects a generic front-end web-server (like
Apache or NGinx) with an backe-end daemon.  The communication reuses
connections.  The front-end server validates and throttles requests to
the back-end daemon.  This module is the base for such back-end daemon.

This module extends the network side of a socket.  During M<accept()>,
each incoming connection will create a new
M<Any::Daemon::FCGI::ClientConn> object which handles the requests.

B<Warning:> the session object lives during the whole client connection,
which may contain requests from different customers.

B<Warning:> this code is new (nov 2019) and only tested with Apache 2.4.
Please report success (and bug-fixes) for other front-end servers.

=chapter METHODS

=c_method new %options
See options of M<IO::Socket::IP> and M<IO::Socket>.
=cut

sub new(%)
{   my ($class, %args) = @_;
    $args{Listen} ||= 5;
    $args{Proto}  ||= 'tcp';
    $class->SUPER::new(%args);
}

#----------------
=section Accessors
=cut

#----------------
=section Actions

=method accept [$pkg]
Wait for a new connection to arrive on the socket.
=cut

sub accept(;$)
{   my $self = shift;
    my $pkg  = shift // 'Any::Daemon::FCGI::ClientConn';
    $self->SUPER::accept($pkg);
}

1;
