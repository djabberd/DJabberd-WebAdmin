#!/usr/bin/perl
use 5.008;
use ExtUtils::MakeMaker;
WriteMakefile(
              NAME         => 'DJabberd::WebAdmin',
              VERSION_FROM => 'lib/DJabberd/WebAdmin.pm',
              ABSTRACT_FROM => 'lib/DJabberd/WebAdmin.pm',
              PREREQ_PM    => {
                  'DJabberd'                => '0.80',
                  'Template'                => '0',
                  'Perlbal'                 => '0',
              },
              AUTHOR     => 'Brad Fitzpatrick <brad@danga.com>',
              );

