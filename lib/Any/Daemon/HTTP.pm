use warnings;
use strict;

package Any::Daemon::HTTP;
use base 'Any::Daemon';

use Log::Report    'any-daemon-http';

use HTTP::Daemon   ();
use IO::Socket     qw/SOCK_STREAM SOMAXCONN/;
use File::Basename qw/basename/;

=chapter NAME
Any::Daemon::HTTP - preforking HTTP daemon

=chapter SYNOPSIS

  my $http = Any::Daemon::HTTP->new(%opts);
  $http->run;

=chapter DESCRIPTION

This module extends the basic M<Any::Daemon> with childs which
handle http connections.  The HTTP/1.1 protocol implementation of
M<HTTP::Daemon> is (ab)used.

Please support my development work by submitting bug-reports, patches
and (if available) a donation.

=chapter METHODS

=c_method new OPTIONS
See the option descriptions of M<Any::Daemon::new()>.

=option  docroot URL
=default docroot 'http://$host'
The root url of this service. When SSL is used, then the url starts with
C<https>.

=option  socket SOCKET
=default socket <created internally>

=option  use_ssl BOOLEAN
=default use_ssl <false>

=option  host HOSTNAME:PORT
=default host <from socket>

=option  server_id STRING
=default server_id <program name>
=cut

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

        $host or error __x"host or socket required for {pkg}::new"
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

    $self->{ADH_ssl}    = $use_ssl;
    $self->{ADH_socket} = $socket;
    $self->{ADH_host}   = $host;
    $self->{ADH_root}   = $args->{docroot}
      || ($use_ssl ? 'https' : 'http'). "://$host";

    $self->{ADH_server} = $args->{server_id} || basename($0);
    $self;
}

#----------------
=section Accessors
=method useSSL
=method host
=method socket
=method docroot
=cut

sub useSSL() {shift->{ADH_ssl}}
sub host()   {shift->{ADH_host}}
sub socket() {shift->{ADH_socket}}
sub docroot(){shift->{ADH_root}}

#----------------
=section Action

=method run OPTIONS

=default child_task <accept http connections>

=option  new_connection CODE
=default new_connection <undef>

=requires handle_request CODE
=cut

sub run(%)
{   my ($self, %args) = @_;

    my $on_new = delete $args{new_connection} || sub {};
    my $handle = delete $args{handle_request} or panic;

    $args{child_task} = sub {
        while(my $client = $self->socket->accept)
        {   info "new client $client using HTTP11";

            # Ugly hack, steal HTTP::Daemon's http/1.1 implementation
            bless $client, $self->{ADH_conn_class};
            ${*$client}{httpd_daemon} = $self;

            while(my $request = $client->get_request)
            {   my $response = $handle->($self, $client, $request);
                $response or next;

                $client->send_response($response);
            }
            $client->close;
        }
        exit 0;
    };

    $self->SUPER::run(%args);
}

# HTTP::Daemon methods used by ::ClientConn.  The names are not compatible
# with MarkOv convention, so hidden for the users of this module
sub url() {shift->{ADH_docroot}}
sub product_tokens() {shift->{ADH_server}}

1;
