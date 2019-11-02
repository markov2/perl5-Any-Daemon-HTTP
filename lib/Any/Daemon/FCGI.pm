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

  my $http = Any::Daemon::HTTP->new
    ( listen    => 'www.example.com'
    , protocol  => 'FCGI'
    );

=chapter DESCRIPTION
The Fast CGI protocol connects a generic web-server (like Apache or NGinx)
with an external daemon.  The communication reuses connections, and the
server validates and throttle requests to the external daemon.  This module
is the base for such external daemon.

This module extends the network side of a socket.  During M<accept()>,
each incoming connection will create an M<Any::Daemon::FCGI::ClientConn>
object which handles the requests.

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