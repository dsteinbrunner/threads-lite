#!perl 

use Test::More 'no_plan';
use Test::Differences;

use threads::lite::list;

my @foo = paralel_map { $_ * 2 } 1..4;

eq_or_diff(\@foo, [ map { $_ * 2} 1 .. 4 ], "tmap { \$_ * 2 } 1..4");
