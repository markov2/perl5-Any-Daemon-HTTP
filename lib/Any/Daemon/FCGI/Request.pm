# This code is part of distribution Any-Daemon-HTTP. Meta-POD processed
# with OODoc into POD and HTML manual-pages.  See README.md
# Copyright Mark Overmeer.  Licensed under the same terms as Perl itself.

package Any::Daemon::FCGI::Request;
use base 'HTTP::Request';

use warnings;
use strict;

use Log::Report      'any-daemon-http';

=chapter NAME
Any::Daemon::FCGI::Request - HTTP::Request with little extras

=chapter SYNOPSIS

=chapter DESCRIPTION

=chapter METHODS

=c_method new %options

=requires request_id INTEGER
Sequence number as used in the FCGI protocol (always > 0, may get reused).

=requires params HASH
The parameters received from the client.

=requires stdin SCALAR
(Ref to string), the body of the message.

=requires role 'RESPONDER'|'AUTHORIZER'|'FILTER'

=option data SCALAR
(Ref to string), the additional data for FILTER requests.

=cut

sub new(%)
{   my ($class, %args) = @_;
    my $params = $args{params} or panic;
    my $role   = $args{role}   or panic;
 
    my @headers;
 
    # Content-Type and Content-Length come specially
    push @headers, 'Content-Type' => $params->{CONTENT_TYPE}
        if exists $params->{CONTENT_TYPE};

    push @headers, 'Content-Length' => $params->{CONTENT_LENGTH}
        if exists $params->{CONTENT_LENGTH};
 
    # Pull all the HTTP_FOO parameters as headers. These will be in all-caps
    # and use _ for word separators, but HTTP::Headers can cope with that.
    foreach (keys %$params)
    {   push @headers, $1 => $params->{$_} if m/^HTTP_(.*)$/;
    }
 
    my $self   = $class->SUPER::new
      ( $params->{REQUEST_METHOD}
      , $params->{REQUEST_URI}
      , \@headers
      , $args{stdin}
      );

    $self->protocol($params->{SERVER_PROTOCOL});

    $self->{ADFR_reqid}  = $args{request_id} or panic;
    $self->{ADFR_params} = $params;
    $self->{ADFR_role}   = $role;
    $self->{ADFR_data}   = $args{data};

    $self;
}

#----------------
=section Accessors

=method request_id
=method params
=method param $name
=method role
=cut

sub request_id { shift->{ADFR_reqid} }
sub params() { shift->{ADFR_params} }
sub param($) { $_[0]->{ADFR_params}{$_[1]} }
sub role()   { shift->{ADFR_role} }

=method data
Returns a reference to the request data.  The params may contain the
modification data as C<FCGI_DATA_LAST_MOD>.
=cut

sub data()   { shift->{ADFR_data} }

1;
