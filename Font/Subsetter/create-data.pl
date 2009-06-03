use strict;
use warnings;

print <<EOF;
package Font::Subsetter::NormalizationData;
use strict;
use warnings;
our \@data = (
EOF

open my $f, '/usr/lib/perl5/5.8.8/unicore/UnicodeData.txt' or die $!;
while (<$f>) {
    my @c = split /;/, $_;
    next unless $c[5] and $c[5] !~ /^</;
    print "[", join(',', map hex($_), split / /, "$c[0] $c[5]"), "],\n";
}

print <<EOF;
);

1;
EOF
