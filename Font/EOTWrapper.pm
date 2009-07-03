# Copyright (c) 2009 Philip Taylor
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

package Font::EOTWrapper;

use strict;
use warnings;

use Font::TTF::Font;
use Encode;

use constant TTEMBED_SUBSET => 0x00000001;
use constant DEFAULT_CHARSET => 0x01;

sub convert {
    my ($in_fn, $out_fn) = @_;

    my $font_data = do {
        open my $fh, $in_fn or die "Failed to open $in_fn: $!";
        binmode $fh;
        local $/;
        <$fh>
    };

    my $font = Font::TTF::Font->open($in_fn) or die "Failed to open $in_fn: $!";

    open my $out, '>', $out_fn or die "Failed to open $out_fn: $!";
    binmode $out;

    $font->{name}->read;

    my $os2 = $font->{'OS/2'};
    $os2->read;

    my $rootString = '';

    my $header = '';
    $header .= pack V => length($font_data);
    $header .= pack V => 0x00020001;
    $header .= pack V => TTEMBED_SUBSET;
    $header .= pack C10 => map $os2->{$_}, qw(bFamilyType bSerifStyle bWeight bProportion bContrast bStrokeVariation bArmStyle bLetterform bMidline bXheight);
    $header .= pack C => DEFAULT_CHARSET;
    $header .= pack C => (($os2->{fsSelection} & 1) ? 1 : 0);
    $header .= pack V => $os2->{usWeightClass};
    $header .= pack v => $os2->{fsType};
    $header .= pack v => 0x504C;
    $header .= pack VVVV => map $os2->{$_}, qw(ulUnicodeRange1 ulUnicodeRange2 ulUnicodeRange3 ulUnicodeRange4);
    $header .= pack VV => map $os2->{$_}, qw(ulCodePageRange1 ulCodePageRange2);
    $header .= pack V => $font->{head}{checkSumAdjustment};
    $header .= pack VVVV => 0, 0, 0, 0;
    $header .= pack v => 0;
    $header .= pack 'v/a*' => encode 'utf-16le' => $font->{name}->find_name(1); # family name
    $header .= pack v => 0;
    $header .= pack 'v/a*' => encode 'utf-16le' => $font->{name}->find_name(2); # style name
    $header .= pack v => 0;
    $header .= pack 'v/a*' => encode 'utf-16le' => $font->{name}->find_name(5); # version name
    $header .= pack v => 0;
    $header .= pack 'v/a*' => encode 'utf-16le' => $font->{name}->find_name(4); # full name
    $header .= pack v => 0;
    $header .= pack 'v/a*' => encode 'utf-16le' => $rootString;

    $out->print(pack V => 4 + length($header) + length($font_data));
    $out->print($header);
    $out->print($font_data);

    $font->release;
}

# sub rootStringChecksum {
#     my $s = 0;
#     $s += $_ for unpack 'C*', $_[0];
#     return $s ^ 0x50475342;
# }

1;
