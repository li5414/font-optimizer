# This script generates various 'interesting' fonts, and outputs an HTML file
# containing the subsetted fonts and the original fonts.
# View the output in browsers (preferably multiple, on multiple platforms) to
# make sure the output looks the same as the original.

use strict;
use warnings;

use lib 'ext/Font-TTF/lib';
use Font::Subsetter;
use Font::EOTWrapper;
use Encode;

use utf8;

# The following fonts need to exist in a directory called 'testfonts':
my @all = qw(
    GenBasR.ttf
    GenR102.TTF
    LinLibertine_Re-4.1.8.ttf
    DoulosSILR.ttf
    DejaVuSans.ttf
    DejaVuSerif.ttf
);

my $index = $ARGV[0];
die "Run '$0', or '$0 n' where n is the number of the test to rebuild\n"
    if defined $index and $index !~ /^\d+$/;

my @tests = (
    [ [qw(DejaVuSans.ttf)], ["fluffily لا f"], [20], [qw(aalt ccmp dlig fina hlig init liga locl medi rlig salt kern mark mkmk)] ],
    [ [qw(DejaVuSans.ttf)], ["fluffily لا f"], [20], [qw(liga)] ],
    [ [qw(DejaVuSans.ttf)], ["fluffily لا f"], [20], [qw(fina init rlig)] ],
    [ [qw(DejaVuSans.ttf)], ["fluffily لا f"], [20], [] ],

    [ [@all], ["Hello world ABC abc 123"], [20] ],
    [ [qw(GenBasR.ttf DejaVuSans.ttf)], [
        "i",
        "\xec",
        "i\x{0300}",
        "i \x{0300}",
        "ixixi",
        "i<span class='h'>\x{0300}</span>",
    ], [20, 8] ],
    [ [qw(LinLibertine_Re-4.1.8.ttf DejaVuSans.ttf)], [
        "fluffily",
        "f<span>l</span>uf<span>f</span>ily",
        "f<span class='h'>l</span>uf<span class='h'>f</span>ily",
    ], [20, 8] ],
    [ [@all], ["VABC(123) fTo fluffiest f<span class='h'>f</span>i!\@#,. \x{00e2}\x{00eb}I\x{0303}o\x{0300}u\x{030a}\x{0305}\x{0303} i\x{0331}\x{0301} \x{0d23}\x{0d4d}\x{200d} παρακαλώ хэлло  你好 表示问候 やあ التل<span class='h'>ف</span>ون הלו"], [20, 8] ],

);

my $common_css = <<EOF;
body {
    font-family: Courier, monospace;
    font-size: 10pt;
}
p {
    margin: 0;
}
.h {
    color: red;
    text-decoration: underline;
}
small {
    font-size: 35%;
}
.box {
    display:inline-block;
    border: 1px #aaa solid;
    padding-left: 4px;
    padding-right: 4px;
}
EOF

my %std_fonts;
# if (0) { my $j = 0;
for my $j (0..$#all) {
    my $fn = $all[$j];
    (my $eot_fn = $fn) =~ s/\.[ot]tf$/.eot/i;
    if (not -e "testfonts/$eot_fn") {
        Font::EOTWrapper::convert("testfonts/$fn", "testfonts/$eot_fn");
    }
    $common_css .= <<EOF;
\@font-face {
    font-family: original-$j;
    src: url(../testfonts/$eot_fn);
}
\@font-face {
    font-family: original-$j;
    src: url(../testfonts/$fn) format("truetype");
}
EOF
    $std_fonts{$all[$j]} = "original-$j";
}

mkdir 'testoutput';

my $out;
if (not defined $index) {
    open $out, '>', 'testoutput/tests.html' or die $!;
    binmode $out, ':utf8';

    print $out <<EOF;
<!DOCTYPE html>
<meta charset="utf-8">
<title>Font tests</title>
<style>
$common_css
</style>
EOF
}

my $i = -1;
for my $test (@tests) {
    for my $fn (@{$test->[0]}) {
        for my $text (@{$test->[1]}) {
            ++$i;
            next if defined $index and $index != $i;

            print encode('utf-8', "$fn -- $text\n");

            (my $text_plain = $text) =~ s/<.*?>//g;

            my $features;
            if ($test->[3]) {
                $features = {};
                $features->{$_} = 1 for @{$test->[3]};
            }

            my $s = new Font::Subsetter();
            $s->subset("testfonts/$fn", $text_plain, $features);
            my $path = sprintf '%03d', $i;
            $s->write("testoutput/$path.ttf");
            my $old_glyphs = $s->num_glyphs_old;
            my $new_glyphs = $s->num_glyphs_new;
            my @glyph_names = $s->glyph_names;
            $s->release;

            Font::EOTWrapper::convert("testoutput/$path.ttf", "testoutput/$path.eot");

            my $fragment = <<EOF;
<style>
\@font-face { /* for IE */
    font-family: subsetted-$i;
    src: url($path.eot);
}
\@font-face {
    font-family: subsetted-$i;
    src: url($path.ttf) format("truetype");
}
</style>
EOF

            for my $size (@{$test->[2]}) {
                $fragment .= <<EOF;
<p title="$fn -- $path -- $old_glyphs vs $new_glyphs" class="box"><span style="font-family: $std_fonts{$fn}; font-size: ${size}pt">$text</span>
<br>
<span style="font-family: subsetted-$i; font-size: ${size}pt">$text</span></p>
EOF
            }

            print $out qq{\n\n$fragment<a href="$path.html">#</a>} if not defined $index;

            open my $html, '>', "testoutput/$path.html";
            binmode $html, ':utf8';
            print $html <<EOF;
<!DOCTYPE html>
<meta charset="utf-8">
<title>Font test $path</title>
<style>
$common_css
.glyphs { font-family: serif; font-size: 10pt; }
.sizes { font-size: 8pt; }
</style>
$fragment
EOF
            print $html qq{<p class="glyphs">}, (join ' &nbsp; ', map "$_", sort @glyph_names), qq{</p>};
            print $html qq{<pre class="sizes">}, dump_sizes("testoutput/$path.ttf"), qq{</pre>};
        }
        print $out "<hr>\n" if not defined $index;
    }
}

sub dump_sizes {
    my ($fn) = @_;
    my $font = Font::TTF::Font->open($fn) or die "Failed to open $fn: $!";

    my $s = 0;
    my $out = '';
    for (sort keys %$font) {
        next if /^ /;
        my $l = $font->{$_}{' LENGTH'};
        $s += $l;
        $out .= "$_: $l\n";
    }
    $out .= "Total: $s\n";
    return $out;
}
