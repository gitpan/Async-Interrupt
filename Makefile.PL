use ExtUtils::MakeMaker;

use 5.008; # apparently PL_sighandlerp was introduced with 5.008 - correct me if wrong

WriteMakefile(
    dist	=> {
	            PREOP	=> 'pod2text Interrupt.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
	            COMPRESS	=> 'gzip -9v',
	            SUFFIX	=> '.gz',
	           },

    PREREQ_PM    => {
       common::sense => 0,
    },
    NAME => "Async::Interrupt",
    VERSION_FROM => "Interrupt.pm",
);

