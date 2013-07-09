use ExtUtils::MakeMaker;

use 5.008;

WriteMakefile
 ( NAME	 	=> 'Any::Daemon::HTTP'
 , VERSION	=> '0.10'
 , PREREQ_PM    =>
   { Log::Report      => '0.90'
   , Any::Daemon      => '0.90'
   , HTTP::Daemon     => '6.01'
   , IO::Socket       => 0
   , IO::Socket::INET => 0
   , File::Basename   => 0
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
