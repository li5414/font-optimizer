#!/usr/bin/perl

use strict;
use warnings;

use lib 'ext/Font-TTF/lib';
use Font::Subsetter;

use Getopt::Long;

main();

sub help {
    print <<EOF;
Usage:
  $0 [options] [inputfile.ttf] [outputfile.ttf]

Options:
  --chars=STRING     characters to include in the subset (defaults to "test")
EOF
    exit 1;
}

sub main {
    my $chars = "test";

    my $result = GetOptions(
        'chars' => \$chars,
    ) or help();

    @ARGV == 2 or help();

    my ($input_file, $output_file) = @ARGV;

    process($input_file, $output_file, $chars);
}

sub process {
    my ($input_file, $output_file, $chars) = @_;

    dump_sizes($input_file);

    print "Generating subsetted font...\n\n";

    my $subsetter = new Font::Subsetter();
    $subsetter->subset($input_file, $chars);
    $subsetter->write($output_file);

    print "\n";

    print "Included glyphs:\n  ";
    print join ' ', $subsetter->glyph_names();
    print "\n\n";

    dump_sizes($output_file);

    $subsetter->release();
}

sub dump_sizes {
    my ($filename) = @_;
    my $font = Font::TTF::Font->open($filename) or die "Failed to open $filename: $!";
    print "TTF table sizes:\n";
    my $s = 0;
    for (sort keys %$font) {
        next if /^ /;
        my $l = $font->{$_}{' LENGTH'};
        $s += $l;
        print "  $_: $l\n";
    }
    print "Total size: $s bytes\n\n";
    $font->release();
}
