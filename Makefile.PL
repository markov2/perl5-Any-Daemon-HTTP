use ExtUtils::MakeMaker;

use 5.008;

WriteMakefile
 ( NAME	 	=> 'Any::Daemon::HTTP'
 , VERSION	=> '0.20'
 , PREREQ_PM    =>
   { Any::Daemon      => '0.91'
   , URI              => 0
   , Encode           => 0
   , English          => 0
   , Fcntl            => 0
   , File::Basename   => 0
   , File::Spec       => 0
   , HTTP::Daemon     => '6.01'
   , HTTP::Response   => 0
   , HTTP::Status     => 0
   , IO::Socket       => 0
   , IO::Socket::INET => 0
   , List::Util       => 0
   , Log::Report      => '0.90'
   , Log::Report      => 0
   , MIME::Types      => 0
   , Net::CIDR        => 0
   , POSIX            => 0
   , Scalar::Util     => 0
   , Socket           => 0
   }

 , EXE_FILES    => []
 , AUTHOR       => 'Mark Overmeer'
 , ABSTRACT     => 'preforking http server'
 , LICENSE      => 'perl'
 );

### used by oodist during production of distribution
sub MY::postamble { <<'__POSTAMBLE' }

# for DIST
EXTENDS		= ../AnyDaemon
RAWDIR          = ../public_html/any-daemon-http/raw
DISTDIR         = ../public_html/any-daemon-http/source
LICENSE         = artistic

# for POD
FIRST_YEAR      = 2013
EMAIL           = perl@overmeer.net
WEBSITE         = http://perl.overmeer.net/any-daemon/
__POSTAMBLE
