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
  --chars=STRING        characters to include in the subset (defaults to "test")
  --verbose, -v         print various details about the font and the subsetting
  --include=FEATURES    comma-separate list of feature tags to include
                        (all others will be excluded by default)
  --exclude=FEATURES    comma-separate list of feature tags to exclude
                        (all others will be included by default)
  --licensesubst=STRING substitutes STRING in place of the string \${LICENSESUBST}
                        in the font's License Description
EOF
    exit 1;
}

sub main {
    my $verbose = 0;
    my $chars = "test";
    my $include;
    my $exclude;
    my $license_desc_subst;

    my $result = GetOptions(
        'chars=s' => \$chars,
        'verbose' => \$verbose,
        'include=s' => \$include,
        'exclude=s' => \$exclude,
        'licensesubst=s' => \$license_desc_subst,
    ) or help();

    @ARGV == 2 or help();

    my ($input_file, $output_file) = @ARGV;


    if ($verbose) {
        dump_sizes($input_file);
        print "Generating subsetted font...\n\n";
    }

    my $features;
    if ($include) {
        $features = { DEFAULT => 0 };
        $features->{$_} = 1 for split /,/, $include;
    } elsif ($exclude) {
        $features = { DEFAULT => 1 };
        $features->{$_} = 0 for split /,/, $exclude;
    }

    my $subsetter = new Font::Subsetter();
    $subsetter->subset($input_file, $chars, { features => $features, license_desc_subst => $license_desc_subst });
    $subsetter->write($output_file);

    if ($verbose) {
        print "\n";
        print "Included glyphs:\n  ";
        print join ' ', $subsetter->glyph_names();
        print "\n\n";
        dump_sizes($output_file);
    }

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
