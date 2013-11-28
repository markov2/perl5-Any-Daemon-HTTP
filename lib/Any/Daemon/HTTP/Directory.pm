use warnings;
use strict;

package Any::Daemon::HTTP::Directory;
use Log::Report  'any-daemon-http';

use Net::CIDR      qw/cidrlookup/;
use File::Spec     ();
use File::Basename qw/dirname/;
use POSIX::1003    qw/strftime :fd :fs/;
use HTTP::Status   qw/:constants/;
use HTTP::Response ();
use Encode         qw/encode/;
use MIME::Types    ();
use List::Util     qw/first/;

my $mimetypes = MIME::Types->new(only_complete => 1);

sub _allow_cleanup($);
sub _allow_match($$$$);
sub _filename_trans($$);

=chapter NAME
Any::Daemon::HTTP::Directory - describe a server directory 

=chapter SYNOPSIS
 # implicit creation of ::Directory object
 my $vh = Any::Daemon::HTTP::VirtualHost
   ->new(directories => {path => '/', location => ...})

 my $vh = Any::Daemon::HTTP::VirtualHost
   ->new(directories => [ \%dir1, \%dir2, $dir_obj ])

 # explicit use
 my $root = Any::Daemon::HTTP::Directory
   ->new(path => '/', location => '...');
 my $vh = Any::Daemon::HTTP::VirtualHost
   ->new(directories => $root);

=chapter DESCRIPTION
Each M<Any::Daemon::HTTP::VirtualHost> will define where the files are
located.  Parts of the URI path can map on different directories,
with different permissions.

User directories, like used in the URI C<<http://xx/~user/yy>>
are implemented in M<Any::Daemon::HTTP::UserDirs>.

=chapter METHODS

=section Constructors

=c_method new OPTIONS|HASH-of-OPTIONS

=option   path PATH
=default  path '/'
If the directory PATH (relative to the document root C<location>) is not
trailed by a '/', it will be made so.

=requires location DIRECTORY|CODE
The DIRECTORY to be prefixed before the path of the URI, or a CODE
reference which will rewrite the path (passed as only parameter) into the
absolute file or directory name.

=option   allow   CIDR|HOSTNAME|DOMAIN|CODE|ARRAY
=default  allow   <undef>
Allow all requests which pass any of these parameters, and none
of the deny parameters.  See L</Allow access>.  B<Be warned> that
the access rights are not inherited from directory configurations
encapsulating this one.

=option   deny    CIDR|HOSTNAME|DOMAIN|CODE|ARRAY
=default  deny    <undef>
See C<allow> and L</Allow access>

=option   index_file STRING|ARRAY
=default  index_file ['index.html', 'index.htm']
When a directory is addressed, it is scanned whether one of these files
exist.  If so, the content will be shown.

=option   directory_list BOOLEAN
=default  directory_list <false>
Enables the display of a directory, when it does not contain one of the
C<index_file> prepared defaults.

=cut

sub new(@)
{   my $class = shift;
    my $args  = @_==1 ? shift : +{@_};
    (bless {}, $class)->init($args);
}

sub init($)
{   my ($self, $args) = @_;

    my $path = $self->{ADHD_path}  = $args->{path} || '/';
    my $loc  = $args->{location}
        or error __x"directory definition requires location";

    my $trans;
    if(ref $loc eq 'CODE')
    {   $trans = $loc;
        undef $loc;
    }
    else
    {   $loc = File::Spec->rel2abs($loc);
        substr($loc, -1) eq '/' or $loc .= '/';
        $trans = _filename_trans $path, $loc;

        -d $loc
            or error __x"directory location {loc} for {path} does not exist"
                 , loc => $loc, path => $path;
    }

    $self->{ADHD_loc}   = $loc;
    $self->{ADHD_fn}    = $trans;
    $self->{ADHD_allow} = _allow_cleanup $args->{allow};
    $self->{ADHD_deny}  = _allow_cleanup $args->{deny};
    $self->{ADHD_dirlist} = $args->{directory_list} || 0;

    my $if = $args->{index_file};
    my @if = ref $if eq 'ARRAY' ? @$if
           : defined $if        ? $if
           : qw/index.html index.htm/;
    $self->{ADHD_indexfns} = \@if;
    $self;
}

#-----------------
=section Attributes
=method path
=method location
=cut

sub path()     {shift->{ADHD_path}}
sub location() {shift->{ADHD_location}}

#-----------------
=section Permissions

=method allow SESSION, REQUEST, URI
BE WARNED that the URI is the rewrite of the REQUEST uri, and therefore
you should use that URI.  The SESSION represents a user.

See L</Allow access>.
=cut

sub allow($$$$)
{   my ($self, $session, $req, $uri) = @_;
    if(my $allow = $self->{ADHD_allow})
    {   $self->_allow_match($session, $uri, $allow) or return 0;
    }
    if(my $deny = $self->{ADHD_deny})
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

=method filename PATH
Convert a URI PATH into a directory path.  Return C<undef> if not possible.
=cut

sub filename($) { $_[0]->{ADHD_fn}->($_[1]) }

sub _filename_trans($$)
{   my ($path, $loc) = @_;
    return $loc if ref $loc eq 'CODE';
    sub
      { my $x = shift;
        $x =~ s!^\Q$path!$loc! or panic "path $x not inside $path";
        $x;
      };
}

=method fromDisk SESSION, REQUEST, URI
Try to produce a response (M<HTTP::Response>) for something inside this
directory structure.  C<undef> is returned if nothing useful is found.
=cut

sub fromDisk($$$)
{   my ($self, $session, $req, $uri) = @_;

    $self->allow($session, $req, $uri)
        or return HTTP::Response->new(HTTP_FORBIDDEN);

    my $item = $self->filename($uri);

    # soft-fail when the item does not exists
    -e $item or return;

    return $self->_file_response($req, $item)
        if -f _;

    return HTTP::Response->new(HTTP_FORBIDDEN)
        if ! -d _;     # neither file nor directory

    return HTTP::Response->new(HTTP_TEMPORARY_REDIRECT, undef
      , [Location => $uri.'/'])
        if substr($item, -1) ne '/';

    foreach my $if (@{$self->{ADHD_indexfns}})
    {   -f $item.$if or next;
         return $self->_file_response($req, $item.$if);
    }

    $self->{ADHD_dirlist}
        or return HTTP::Response->new(HTTP_FORBIDDEN, "no directory lists");

    $self->_list_response($req, $uri, $item);
}

sub _file_response($$)
{   my ($self, $req, $fn) = @_;

    -f $fn
        or return HTTP::Response->new(HTTP_NOT_FOUND);

    open my($fh), '<:raw', $fn
        or return HTTP::Response->new(HTTP_FORBIDDEN);

    my ($dev, $inode, $mtime) = (stat $fh)[0,1,9];
    my $etag      = "$dev-$inode-$mtime";

    my $has_etag  = $req->header('If-None_Match');
    return HTTP::Response->new(HTTP_NOT_MODIFIED, 'match etag')
        if defined $has_etag && $has_etag eq $etag;

    my $has_mtime = $req->if_modified_since;
    return HTTP::Response->new(HTTP_NOT_MODIFIED, 'unchanged')
        if defined $has_mtime && $has_mtime >= $mtime;

    my $head = HTTP::Headers->new;

    my $ct;
    if(my $mime = $mimetypes->mimeTypeOf($fn))
    {   $ct  = $mime->type;
        $ct .= "; charset='utf8'" if $mime->isAscii;
    }
    else
    {   $ct  = 'binary/octet-stream';
    }

    $head->content_type($ct);
    $head->last_modified($mtime);
    $head->header(ETag => $etag);

    local $/;
    my $resp = HTTP::Response->new(HTTP_OK, undef, $head, <$fh>);

    $resp;
}

sub _list_response($$$)
{   my ($self, $req, $uri, $dir) = @_;

    no warnings 'uninitialized';

    my $list = $self->list($dir);

    my $now  = localtime;
    my @rows;
    push @rows, <<__UP if $dir ne '/';
<tr><td colspan="5">&nbsp;</td><td><a href="../">(up)</a></td></tr>
__UP

    foreach my $item (sort keys %$list)
    {   my $d = $list->{$item};
        push @rows, <<__ROW;
<tr><td>$d->{flags}</td>
    <td>$d->{user}</td>
    <td>$d->{group}</td>
    <td align="right">$d->{size_nice}</td>
    <td>$d->{mtime_nice}</td>
    <td><a href="$d->{name}">$d->{name}</a></td></tr>
__ROW
    }

    local $" = "\n";
    my $content = encode 'utf8', <<__PAGE;
<html><head><title>$dir</title></head>
<style>TD { padding: 0 10px; }</style>
<body>
<h1>Directory $dir</h1>
<table>
@rows
</table>
<p><i>Generated $now</i></p>
</body></html>
__PAGE

    HTTP::Response->new(HTTP_OK, undef
      , ['Content-Type' => 'text/html; charset="utf8"']
      , $content
      );
}

=method list DIRECTORY, OPTIONS
Returns a HASH with information about the DIRECTORY content.  This may
be passed into some template or the default template.  See L</Return of
directoryList> about the returned output.

=option  names CODE|Regexp
=default names <skip hidden files>
Reduce the returned list.  The CODE reference is called with the found
filename, and should return true when the name is acceptable.  The
default regexp (on UNIX) is C<< qr/^[^.]/ >>

=option  filter CODE
=default filter <undef>
For each of the selected names (see  C<names> option) the lstat() is
called.  That data is expanded into a HASH, but not all additional
fields are yet filled-in (only the ones which come for free).

=option  hide_symlinks BOOLEAN
=default hide_symlinks <false>
=cut

my %filetype =
  ( &S_IFSOCK => 's', &S_IFLNK => 'l', &S_IFREG => '-', &S_IFBLK => 'b'
  , &S_IFDIR  => 'd', &S_IFCHR => 'c', &S_IFIFO => 'p');

my @flags    = ('---', '--x', '-w-', '-wx', 'r--', 'r-x', 'rw-', 'rwx');
    
my @stat_fields =
   qw/dev ino mode nlink uid gid rdev size atime mtime ctime blksize blocks/;

sub list($@)
{   my ($self, $dirname, %opts) = @_;

    opendir my $from_dir, $dirname
        or return;

    my $names      = $opts{names} || qr/^[^.]/;
    my $prefilter
       = ref $names eq 'Regexp' ? sub { $_[0] =~ $names }
       : ref $names eq 'CODE'   ? $names
       : panic "::Directory::list(names) must be regexp or code, not $names";

    my $postfilter = $opts{filter} || sub {1};
    ref $postfilter eq 'CODE'
        or panic "::Directory::list(filter) must be code, not $postfilter";

    my $hide_symlinks = $opts{hide_symlinks};

    my (%dirlist, %users, %groups);
    foreach my $name (grep $prefilter->($_), readdir $from_dir)
    {   my $path = $dirname.$name;
        my %d    = (name => $name, path => $path);
        @d{@stat_fields}
            = $hide_symlinks ? stat($path) : lstat($path);

           if(!$hide_symlinks && -l _)
                    { @d{qw/kind is_symlink  /} = ('SYMLINK',  1)}
        elsif(-d _) { @d{qw/kind is_directory/} = ('DIRECTORY',1)}
        elsif(-f _) { @d{qw/kind is_file     /} = ('FILE',     1)}
        else        { @d{qw/kind is_other    /} = ('OTHER',    1)}

        $postfilter->(\%d)
            or next;

        if($d{is_symlink})
        {   my $sl = $d{symlink_dest} = readlink $path;
            $d{symlink_dest_exists} = -e $sl;
        }
        elsif($d{is_file})
        {   my ($s, $l) = ($d{size}, '  ');
            ($s,$l) = ($s/1024, 'kB') if $s > 1024;
            ($s,$l) = ($s/1024, 'MB') if $s > 1024;
            ($s,$l) = ($s/1024, 'GB') if $s > 1024;
            $d{size_nice} = sprintf +($s>=100?"%.0f%s":"%.1f%s"), $s,$l;
        }
        elsif($d{is_directory})
        {   $d{name} .= '/';
        }

        if($d{is_file} || $d{is_directory})
        {   $d{user}  = $users{$d{uid}} ||= getpwuid $d{uid};
            $d{group} = $users{$d{gid}} ||= getgrgid $d{gid};
            my $mode = $d{mode};
            my $b = $filetype{$mode & S_IFMT} || '?';
            $b   .= $flags[ ($mode & S_IRWXU) >> 6 ];
            substr($b, -1, -1) = 's' if $mode & S_ISUID;
            $b   .= $flags[ ($mode & S_IRWXG) >> 3 ];
            substr($b, -1, -1) = 's' if $mode & S_ISGID;
            $b   .= $flags[  $mode & S_IRWXO ];
            substr($b, -1, -1) = 't' if $mode & S_ISVTX;
            $d{flags}      = $b;
            $d{mtime_nice} = strftime "%F %T", localtime $d{mtime};
        }
        $dirlist{$name} = \%d;
    }
    \%dirlist;
}

#-----------------------
=chapter DETAILS

=section Directory limits

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
 MyVHOST->new( allow =>
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

 Any::Daemon::HTTP::VirtualHost->new(allow => \&my_rules);

 sub my_rules($$$$)   # called before each request
 {   my ($ip, $host, $session, $uri) = @_;
     # return true if access is permitted
 }

=section Return of list()

The M<list()> method returns a HASH of HASHes, where the
primary keys are the directory entries, each refering to a HASH
with details.  It is designed to ease the connection to template
systems.

The details contain the C<lstat> information plus some additional
helpers.  The lstat call provides the fields C<dev>, C<ino>, C<mode>,
C<nlink>, C<uid>, C<gid>, C<rdev>, C<size>,  C<atime>, C<mtime>,
C<ctime>, C<blksize>, C<blocks> -as far as supported by your OS.
The entry's C<name> and C<path> are added.

The C<kind> field contains the string C<DIRECTORY>, C<FILE>, C<SYMLINK>,
or C<OTHER>.  Besides, you get either an C<is_directory>, C<is_file>,
C<is_symlink>, or C<is_other> field set to true.  Equivalent are:

   if($entry->{kind} eq 'DIRECTORY')
   if($entry->{is_directory})

It depends on the kind of entry which of the following fields are added
additionally.  Symlinks will get C<symlink_dest>, C<symlink_dest_exists>.
Files hace the C<size_nice>, which is the size in pleasant humanly readable
format.

Files and directories have the C<mtime_nice> (in localtime).  The C<user> and
C<group> which are textual representations of the numeric uid and gid are
added.  The C<flags> represents the UNIX standard permission-bit display,
as produced by the "ls -l" command.

=cut

1;
