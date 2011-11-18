use ExtUtils::MakeMaker;
#See lib/ExtUtils/MakeMaker.pm for details of how to influence
#the contents of the Makefile that is written.
%_ = (
  NAME         => 'App::watchmen',
  DISTNAME     => 'watchmen',
  VERSION_FROM => 'watchmen',
  INSTALLDIRS  => 'bin',
  PREREQ_PM    => { 'Time::HiRes' => '0', 'LWP::UserAgent' => '0', 'URI::URL' => '0', 'MIME::Lite' => 0, },
  EXE_FILES    => ['watchmen'],
);
WriteMakefile(%_);

sub MY::postamble {
  qq{
docs: README

README: $_{VERSION_FROM}
	pod2text $_{VERSION_FROM} > README

tidy:
	perltidy -b -i=2 -ce -l=128 -nbbc -sob -otr -sot *.PL watchmen 

fullclean: distclean clean
	rm -f \$(DISTNAME)-*.tar.gz *.bak *.old *.log MANIFEST README
	rm -Rf nytprof*

release: fullclean docs manifest metafile dist
}
}
