#!/usr/bin/perl
my $c="Current time: ".localtime()."\n";
print "Content-Type: text/plain\n";
print "Content-Length: ".length($c)."\n";
print "\n";
print $c;
