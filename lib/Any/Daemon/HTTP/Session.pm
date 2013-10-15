use strict;
use warnings;

package Any::Daemon::HTTP::Session;

use Log::Report    'any-daemon-http';

use Socket         qw(inet_aton AF_INET);

=chapter NAME
Any::Daemon::HTTP::Session - represents a client connection

=chapter SYNOPSIS

=chapter DESCRIPTION
The connection relates to one client.  Each time, some browser connects
to the socket, a new ::Session object will be created.  It can be used
to cache information as well.

=chapter METHODS

=section Constructors

=c_method new OPTIONS

=requires client IO::Socket-client

=option  store HASH
=default store {}
=cut

sub new(%)  {my $class = shift; (bless {}, $class)->init({@_})}
sub init($)
{   my ($self, $args) = @_;
    my $client = $self->{ADHC_store} = $args->{client} or panic;
    my $store  = $self->{ADHC_store} = $args->{store} || {};

    my $peer   = $store->{peer}    ||= {};
    my $ip     = $peer->{ip}       ||= $client->peerhost;
    $peer->{host} = gethostbyaddr inet_aton($ip), AF_INET;

    $self;
}

#-----------------
=section Accessors
=method client
=method get NAMES
=method set NAME, VALUE
=cut

sub client() {shift->{ADHC_client}}
sub get(@)   {my $s = shift->{ADHC_store}; wantarray ? @{$s}{@_} : $s->{$_[0]}}
sub set($$)  {$_[0]->{ADHC_store}{$_[1]} = $_[2]}

1;
