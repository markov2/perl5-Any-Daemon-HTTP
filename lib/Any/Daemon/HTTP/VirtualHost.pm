use warnings;
use strict;

package Any::Daemon::HTTP::VirtualHost;
use Log::Report    'any-daemon-http';

use Any::Daemon::HTTP::Directory;
use Any::Daemon::HTTP::UserDirs;
use Any::Daemon::HTTP::Proxy;

use HTTP::Status qw/:constants/;
use List::Util   qw/first/;
use File::Spec   ();
use POSIX::1003  qw(strftime);
use Scalar::Util qw(blessed);
use Digest::MD5  qw(md5_base64);

=chapter NAME
Any::Daemon::HTTP::VirtualHost - webserver virtual hosts

=chapter SYNOPSIS

 my $vhost  = Any::Daemon::HTTP::VirtualHost->new
  ( directories => ...
  , rewrite     => ...
  , handlers    => ...
  );
 my $daemon = Any::Daemon::HTTP->new
   ( @other_options
   , vhosts  => $vhost  # or \@vhosts
   );

 # or
 my $daemon = Any::Daemon::HTTP->new(@other_opts);
 $daemon->addVirtualHost($vhost);
 $daemon->addVirtualHost(@vhost2_opts);

 # create object which extends Any::Daemon::HTTP::VirtualHost
 my $myvhost = MyVHost->new(...);
 $daemon->addVirtualHost($myvhost);

=chapter DESCRIPTION
These virtual host definitions are used by M<Any::Daemon::HTTP>, to
implement (server) name based data seperation.  Its features resemble those
of Apache virtual hosts.

Each virtual host usually has to M<Any::Daemon::HTTP::Directory> slaves: one
which describes the permissions for user directories (url paths in the
form C< /~user/ >) and one for data outside the user space.

=chapter METHODS

=section Constructors
You may avoid the creation of extension classes for each virtual host,
by using these options.

=c_method new OPTIONS|HASH-of-OPTIONS

=requires name    HOSTNAME

=option   aliases HOSTNAME|ARRAY-of-HOSTNAMES
=default  aliases []

=option   rewrite CODE|METHOD|HASH
=default  rewrite <undef>
When a request arrives, the URI can be rewritten to become an other
request. See L</URI rewrite>.

[0.21] When a METHOD name is specified, that will be called on
the virtual host object.  An HASH as parameter is interpreted as a
simple lookup table.

=option   redirect CODE|METHOD|HASH
=default  redirect <undef>
[0.21] Automatically redirect the browser to some other url, maybe to
an other host.  Configuration like for C<rewrite>.

=option   documents DIRECTORY
=default  documents <undef>
An absolute DIRECTORY for the location of the source files.  Creates the
most free M<Any::Daemon::HTTP::Directory> object.  If you need things like
access restrictions, then do not use this option but the C<directories>
option.

=option   directories OBJECT|HASH|ARRAY
=default  directories <see text>
Pass one or more M<Any::Daemon::HTTP::Directory> OBJECTS, or HASHes which will
be used to initialize them.

=option   user_dirs undef|OBJECT|HASH
=default  user_dirs C<undef>
With an (empty?) HASH which contains instantiation parameter, an
M<Any::Daemon::HTTP::UserDirs> is created for you, with
standard Apache behavior.  You may provide your own OBJECT.  Without
this parameter, there are no public user pages.

=option   proxies OBJECT|HASH|ARRAY
=default  proxies C<undef>
Pass one or more M<Any::Daemon::HTTP::Proxy> OBJECTS, or HASHes which
will be used to initialize them.

=option   handlers CODE|HASH
=default  handlers {}
The keys are path names, part of the request URIs.  The values are
CODE-references, called when that URI is addressed.  The access rules
are taken from the directory definition which is selected by the path.
Read L</DETAILS> for the details.

=cut

sub new(@)
{   my $class = shift;
    my $args  = @_==1 ? shift : {@_};
    (bless {}, $class)->init($args);
}

sub init($)
{   my ($self, $args) = @_;

    my $name = $self->{ADHV_name} = $args->{name};
    defined $name
        or error __x"virtual host {pkg} has no name", pkg => ref $self;

    my $aliases = $args->{aliases} || [];
    $self->{ADHV_aliases}  = ref $aliases eq 'ARRAY' ? $aliases : [$aliases];
    $self->{ADHV_handlers} = $args->{handler} || $args->{handlers} || {};
    $self->{ADHV_rewrite}  = $self->_rewrite_call($args->{rewrite});
    $self->{ADHV_redirect} = $self->_redirect_call($args->{redirect});
    $self->{ADHV_udirs}    = $self->_user_dirs($args->{user_dirs});

    $self->{ADHV_sources}     = {};
    $self->_auto_docs($args->{documents});
    my $dirs = $args->{directories} || [];
    $self->addDirectory($_) for ref $dirs eq 'ARRAY' ? @$dirs : $dirs;

    $self->{ADHV_proxies}  = {};
    my $proxies = $args->{proxies}  || [];
    $self->addProxy($_) for ref $proxies eq 'ARRAY' ? @$proxies : $proxies;

    $self;
}

sub _user_dirs($)
{   my ($self, $dirs) = @_;
    $dirs or return undef;

    return Any::Daemon::HTTP::UserDirs->new($dirs)
        if ref $dirs eq 'HASH';

    return $dirs
        if $dirs->isa('Any::Daemon::HTTP::UserDirs');

    error __x"vhost {name} user_dirs is not an ::UserDirs object"
      , name => $self->name;
}

sub _auto_docs($)
{   my ($self, $docroot) = @_;
    $docroot or return;

    File::Spec->file_name_is_absolute($docroot)
        or error __x"vhost {name} documents directory must be absolute"
             , name => $self->name;

    -d $docroot
        or error __x"vhost {name} documents `{dir}' must point to dir"
             , name => $self->name, dir => $docroot;

    $docroot =~ s/\\$//; # strip trailing / if present
    $self->addDirectory(path => '/', location => $docroot);
}

#---------------------
=section Attributes

=method name
Returns the primary name for this server.

=method aliases
Returns a list of all aliases (alternative names) for this server.
=cut

sub name()    {shift->{ADHV_name}}
sub aliases() {@{shift->{ADHV_aliases}}}

#---------------------
=section Handler

=method addHandler CODE|(PATH => CODE)-LIST|HASH
Handlers are called to dynamically generate responses, for instance
to fill-in templates.  The L</DETAILS> section below explains how
handlers work.

When only CODE is given, then this will be the default handler for all
paths (under '/', top).  You may also pass a list or HASH of PAIRS.
[0.21] CODE may also be a method name.

=example
  $vhost->addHandler('/' => \&default_handler,
      '/upload' => \&upload_handler);

  $vhost->addHandler(\&default_handler);

  # [0.21] will call $vhost->formHandle
  $vhost->addHandler('/form' => 'formHandler');
=cut

sub addHandler(@)
{   my $self = shift;
    my @pairs
       = @_ > 1              ? @_
       : ref $_[0] eq 'HASH' ? %{$_[0]}
       :                       ( '/' => $_[0]);
    
    my $h = $self->{ADHV_handlers} ||= {};
    while(@pairs)
    {   my $k    = shift @pairs;
        substr($k, 0, 1) eq '/'
            or error __x"handler path must be absolute, for {rel} in {vhost}"
                 , rel => $k, vhost => $self->name;

        my $v    = shift @pairs;
        unless(ref $v)
        {   my $method = $v;
            $self->can($method)
                or error __x"handler method {name} not provided by {vhost}"
                    , name => $method, vhost => ref $self;
            $v = sub { shift->$method(@_) };
        }

        $h->{$k} = $v;
    }
    $h;
}

=method addHandlers PARAMS
Same as M<addHandler()>.
=cut

*addHandlers = \&addHandler;

=method findHandler URI|PATH|PATH-SEGMENTS
=cut

sub findHandler(@)
{   my $self = shift;
    my @path = @_>1 ? @_ : ref $_[0] ? $_[0]->path_segments : split('/', $_[0]);

    my $h = $self->{ADHV_handlers} ||= {};
    while(@path)
    {   my $handler = $h->{join '/', @path};
        return $handler if $handler;
        pop @path;
    }
    
    sub {HTTP::Response->new(HTTP_NOT_FOUND)}
}

#-----------------
=section Access permissions
=cut


#-----------------
=method handleRequest SERVER, SESSION, REQUEST, [URI]
=cut

sub handleRequest($$$;$)
{   my ($self, $server, $session, $req, $uri) = @_;

    $uri      ||= $req->uri;
    my $new_uri = $self->rewrite($uri);

    if(my $redir = $self->mustRedirect($new_uri))
    {   return $redir;
    }

    if($new_uri ne $uri)
    {   info __x"{vhost} rewrote {uri} into {new}"
          , vhost => $self->name, uri => $uri, new => $new_uri;
        $uri = $new_uri;
    }

    my $path   = $uri->path;
    info __x"{vhost} request {path}", vhost => $self->name, path => $uri->path;

    my @path   = $uri->path_segments;
    my $source = $self->sourceFor(@path);

    # static content?
    my $resp   = $source ? $source->collect($self, $session, $req,$uri) : undef;
    return $resp if $resp;

    # dynamic content
    $resp = $self->findHandler(@path)->($self, $session, $req, $uri, $source);
    $resp or return HTTP::Response->new(HTTP_NO_CONTENT);

    $resp->code eq HTTP_OK
        or return $resp;

    # cache dynamic content based on md5 checksum
    my $etag     = md5_base64 ${$resp->content_ref};
    my $has_etag = $req->headers->header('ETag');
    return HTTP::Response->new(HTTP_NOT_MODIFIED, 'cached dynamic data')
        if $has_etag && $has_etag eq $etag;

    $resp->headers->header(ETag => $etag);
    $resp;
}

#----------------------
=section Basic daemon actions

=method rewrite URI
Returns an URI object as result, which may be the original in case of
no rewrite was needed.  See L</URI Rewrite>.
=cut

sub rewrite($) { $_[0]->{ADHV_rewrite}->(@_) }

sub _rewrite_call($)
{   my ($self, $rew) = @_;
    $rew or return sub { $_[1] };
    return $rew if ref $rew eq 'CODE';

    if(ref $rew eq 'HASH')
    {   my %lookup = %$rew;
        return sub {
            my $uri = $_[1]            or return undef;
            exists $lookup{$uri->path} or return $uri;
            URI->new_abs($lookup{$uri->path}, $uri)
        };
    }

    if(!ref $rew)
    {   return sub {shift->$rew(@_)}
            if $self->can($rew);

        error __x"rewrite rule method {name} in {vhost} does not exist"
          , name => $rew, vhost => $self->name;
    }

    error __x"unknown rewrite rule type {ref} in {vhost}"
      , ref => (ref $rew || $rew), vhost => $self->name;
}

=method redirect URI, [HTTP_CODE]
[0.21] Returns an M<HTTP::Response> object of the URI.
=cut

sub redirect($;$)
{   my ($self, $uri, $code) = @_;
    HTTP::Response->new($code//HTTP_TEMPORARY_REDIRECT, undef
      , [ Location => "$uri" ]
    );
}

=method mustRedirect URI
[0.21] Returns an M<HTTP::Response> object if the URI needs to be
redirected, according to the vhost configuration.
=cut

sub mustRedirect($)
{   my ($self, $uri) = @_;
    my $new_uri = $self->{ADHV_redirect}->($self, $uri);
    $new_uri && $new_uri ne $uri or return;

    info __x"{vhost} redirecting {uri} to {new}"
      , vhost => $self->name, uri => $uri->path, new => "$new_uri";

    $self->redirect($new_uri);
}

sub _redirect_call($)
{   my ($self, $red) = @_;
    $red or return sub { $_[1] };
    return $red if ref $red eq 'CODE';

    if(ref $red eq 'HASH')
    {   my %lookup = %$red;
        return sub {
            my $uri = $_[1]            or return undef;
            exists $lookup{$uri->path} or return undef;
            URI->new_abs($lookup{$uri->path}, $uri);
        };
    }

    if(!ref $red)
    {   return sub {shift->$red(@_)}
            if $self->can($red);

        error __x"redirect rule method {name} in {vhost} does not exist"
          , name => $red, vhost => $self->name;
    }

    error __x"unknown redirect rule type {ref} in {vhost}"
      , ref => (ref $red || $red), vhost => $self->name;
}

=method addSource SOURCE
The SOURCE objects extend M<Any::Daemon::HTTP::Source>, for instance a
C<::Directory> or a C<::Proxy>.  You can find them back via M<sourceFor()>.
=cut

sub addSource($)
{   my ($self, $source) = @_;
    $source or return;

    my $sources = $self->{ADHV_sources};
    my $path    = $source->path;

    if(my $old = exists $sources->{$path})
    {   error __x"vhost {name} directory `{path}' defined twice, for `{old}' and `{new}' "
           , name => $self->name, path => $path
           , old => $old->name, new => $source->name;
    }

    info __x"add configuration `{name}' to {vhost} for {path}"
      , name => $source->name, vhost => $self->name, path => $path;

    $sources->{$path} = $source;
}

#------------------
=section Directories

=method filename URI
Translate the URI into a filename, without checking for existence.  Returns
C<undef> is not possible.
=cut

sub filename($)
{   my ($self, $uri) = @_;
    my $dir = $self->sourceFor($uri);
    $dir ? $dir->filename($uri->path) : undef;
}

=method addDirectory OBJECT|HASH|OPTIONS
Either pass a M<Any::Daemon::HTTP::Directory> OBJECT or the OPTIONS to
create the object.  When OPTIONS are provided, they are passed to
M<Any::Daemon::HTTP::Directory::new()> to create the OBJECT.
=cut

sub addDirectory(@)
{   my $self = shift;
    my $dir  = @_==1 && blessed $_[0] ? shift
       : Any::Daemon::HTTP::Directory->new(@_);

    $self->addSource($dir);
}

=method sourceFor PATH|PATH_SEGMENTS
Find the best matching M<Any::Daemon::HTTP::Source> object, which
might be a C<::UserDirs>, a C<::Directory>, or a C<::Proxy>.
=cut

sub sourceFor(@)
{   my $self  = shift;
    my @path  = @_>1 || index($_[0], '/')==-1 ? @_ : split('/', $_[0]);

    return $self->{ADHV_udirs}
        if substr($path[0], 0, 1) eq '~';

    my $sources = $self->{ADHV_sources};
    while(@path)
    {   my $dir = $sources->{join '/', @path};
        return $dir if $dir;
        pop @path;
    }
    $sources->{'/'} ? $sources->{'/'} : ();
}

#-----------------------------
=section Proxies

=method addProxy OBJECT|HASH|OPTIONS
Either pass a M<Any::Daemon::HTTP::Proxy> OBJECT or the OPTIONS to
create the object.  When OPTIONS are provided, they are passed to
M<Any::Daemon::HTTP::Proxy::new()> to create the OBJECT.
=cut

sub addProxy(@)
{   my $self  = shift;
    my $proxy = @_==1 && blessed $_[0] ? shift
       : Any::Daemon::HTTP::Proxy->new(@_);

    error __x"proxy {name} has a map, so cannot be added to a vhost"
      , name => $proxy->name
        if $proxy->forwardMap;

    info __x"add proxy configuration to {vhost} for {path}"
      , vhost => $self->name, path => $proxy->path;

    $self->addSource($proxy);
}

#-----------------------------

=chapter DETAILS

=section Handlers

Handlers are called to dynamically generate responses, for instance
to fill-in templates.

When a request for an URI is received, it is first checked whether
a static file can fulfil the request.  If not, a search is started
for the handler with the longest path.

  # /upload($|/*) goes to the upload_handler
  $vhost->addHandler
    ( '/'       => \&default_handler
    , '/upload' => \&upload_handler
    );

  # Missing files go to the default_handler
  # which is actually replacing the existing one
  $vhost->addHandler(\&default_handler);

  # [0.21] This will call $vhost->formHandle(...), especially
  # useful in your virtual host sub-class.
  $vhost->addHandler('/form' => 'formHandler');

The handlers are called with many arguments, and should return an
M<HTTP::Response> object:

  $vhost->addHandler('/upload' => $handler);
  my $resp = $hander->($vhost, $session, $req, $uri, $tree);

  $vhost->addHandler('/form' => $method);
  my $resp = $vhost->$method($session, $req, $uri, $tree);

In which
=over 4
=item * C<$vhost> is an C<Any::Daemon::HTTP::VirtualHost>,
=item * C<$session> is an M<Any::Daemon::HTTP::Session>,
=item * C<$req> is an M<HTTP::Request>,
=item * C<$uri> an M<URI> after rewrite rules, and
=item * C<$tree> the selected C<Any::Daemon::HTTP::Directory>.
=back

The handler could work like this:

  sub formHandler($$$$)
  {   my ($vhost, $session, $req, $uri, $tree) = @_;
      # in OO extended vhosts, then $vhost => $self

      # Decode path parameters in Plack style
      # ignore two components: '/' and 'form' from the path
      my (undef, undef, $name, @more) = $uri->path_segments;

      HTTP::Response->new(HTTP_OK, ...);
  }
  
=section Your virtual host as class

When your virtual host has larger configuration or many handlers --or when
you like clean programming--, it may be a good choice to put your code
in a separate package with the normal Object Oriented extension mechanism.

You may need to implement your own information persistence via databases
or configation files.  For that, extend M<Any::Daemon::HTTP::Session>.

=example own virtual host

  package My::Service;
  use parent 'Any::Daemon::HTTP::VirtualHost';

  sub init($)
  {   my ($self, $args) = @_;
      $args->{session_class} = 'My::Service::Session';
      $self->SUPER::init($args);
      
      $self->addDirectory(...);
      $self->addHandler(a => 'ah');
      ... etc ...
      $self;
  }

  sub ah($$$$)
  {   my ($self, $session, $request, $uri, $tree) = @_;
      return HTTP::Response->new(...);
  }

  package My::Service::Session;
  use parent 'Any::Daemon::HTTP::Session';

=section URI Rewrite

For each request, the M<rewrite()> method is called to see whether a
rewrite of the URI is required.  The method must return the original URI
object (the only parameter) or a new URI object.

=example usage

  my $vhost = Any::Daemon::HTTP::VirtualHost
    ->new(..., rewrite => \&rewrite);

  my $vhost = My::Service     # see above
    ->new(..., rewrite => 'rewrite');

  my $vhost = My::Service     # see above
    ->new(..., rewrite => \%lookup_table);

=example rewrite URI

  my %lookup =
    ( '/'     => '/index-en.html'
    , '/news' => '/news/2013/index.html'
    );

  sub rewrite($)
  {  my ($vhost, $uri) = @_;
     # when called as method, $vhost --> $self

     # with lookup table
     $uri = URI->new_abs($lookup{$uri->path}, $uri)
         if exists $lookup{$uri->path};

     # whole directory trees
     $uri = URI->new_abs('/somewhere/else'.$1, $uri)
         if $uri->path =~ m!^/some/dir(/.*|$)!;
     
     $uri;
  }

=section Using Template::Toolkit
 
Connecting this server to the popular M<Template::Toolkit> webpage
framework is quite simple:

  # Use TT only for pages under /status
  $vhost->addHandler('/status' => 'ttStatus');

  sub ttStatus($$$$)
  {   my ($self, $session, $request, $uri, $tree) = @_;;
      my $template = Template->new(...);

      my $output;
      my $values = {};  # collect the values
      $template->process($fn, $values, \$output)
          or die $template->error, "\n";

      HTTP::Response->new(HTTP_OK, undef
        , ['Content-Type' => 'text/html']
        , "$output"
        );
  }

See M<Log::Report::Extract::Template> if you need translations
as well.
=cut

1;
