use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
%_ = (
  NAME          => 'watchmen',
  VERSION_FROM  => 'watchmen.pl',
  INSTALLDIRS   => 'bin',
  PREREQ_PM     => { 'Time::HiRes' => '0', 'LWP::UserAgent' => '0', 'URI::URL' => '0', },
  ABSTRACT_FROM => 'watchmen.pl',
);
WriteMakefile(%_);

sub MY::postamble {
  qq{
docs: README

README: $_{VERSION_FROM}
	pod2text $_{VERSION_FROM} > README

fullclean: distclean clean
	rm -f \$(DISTNAME)-*.tar.gz *.bak *.old *.log MANIFEST README

release: fullclean docs manifest metafile dist
}
}
