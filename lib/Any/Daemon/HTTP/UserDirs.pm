use warnings;
use strict;

package Any::Daemon::HTTP::UserDirs;
use parent 'Any::Daemon::HTTP::Directory';

use Log::Report    'any-daemon-http';

=chapter NAME
Any::Daemon::HTTP::UserDirs - describe user directories

=chapter SYNOPSIS
 # implicit creation of ::Directory object
 my $vh = Any::Daemon::HTTP::VirtualHost
   ->new(user_dirs => {location => ...})

 # explicit use
 my $ud = Any::Daemon::HTTP::Directory::UserDirs
   ->new(location => sub {...});
 my $vh = Any::Daemon::HTTP::VirtualHost->new(user_dirs => $ud);

=chapter DESCRIPTION
Each M<Any::Daemon::HTTP::VirtualHost> may define user directories.

=chapter METHODS

=section Constructors

=c_method new OPTIONS|HASH-of-OPTIONS

=default  path <ignored>

=default  location CODE
The user-dir rewrite routine has by default Apache-like behavior.

=option   user_subdirs PATH
=default  user_subdirs 'public_html'
Only used with the default user-dir rewrite rule.

=option   allow_users ARRAY
=default  allow_users undef
Lists the user homes which are available.  Cannot be used together with
C<deny_users>.  By default, all user homes are permitted, even those
of system usernames like C<ftp> and C<cups>.
Only used with the default user-dir rewrite rule.

=option   deny_users  ARRAY
=default  deny_users  []
Only used with the default user-dir rewrite rule.

=cut

sub init($)
{   my ($self, $args) = @_;

    my $subdirs = $args->{user_subdirs} || 'public_html';
    my %allow   = map +($_ => 1), @{$args->{allow_users} || []};
    my %deny    = map +($_ => 1), @{$args->{deny_users}  || []};
    $args->{location} ||= $self->userdirRewrite($subdirs, \%allow, \%deny);

    $self->SUPER::init($args);
    $self;
}

#-----------------
=section Attributes
=cut

sub userdirRewrite($$$)
{   my ($self, $udsub, $allow, $deny) = @_;
    my %homes;  # cache
    sub { my $path = shift;
          my ($user, $pathinfo) = $path =~ m!^/\~([^/]*)(.*)!;
          return if keys %$allow && !$allow->{$user};
          return if keys %$deny  &&  $deny->{$user};
          return if exists $homes{$user} && !defined $homes{$user};
          my $d = $homes{$user} ||= (getpwnam $user)[7];
          $d ? "$d/$udsub$pathinfo" : undef;
        };
}

1;
