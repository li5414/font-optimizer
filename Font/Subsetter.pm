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

package Font::Subsetter;

use strict;
use warnings;

use Carp;
use Unicode::Normalize();
use Digest::SHA qw(sha1_hex);

use Font::TTF;
use Font::TTF::Font;

if ($Font::TTF::VERSION =~ /^0\.([0-3].|4[0-5])$/) {
    die "You are using an old version of Font::TTF ($Font::TTF::VERSION) - you need at least v0.46, and preferably the latest SVN trunk from <http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=fontutils>.";
}

# Tables can be:
#   REQUIRED - will fail if it's not present
#   FORBIDDEN - will fail if it's present
#   OPTIONAL - will be accepted regardless of whether it's there or not
#   IGNORED - like OPTIONAL, but no processing will take place
#   UNFINISHED - will emit a warning if it's present, because the code doesn't handle it properly yet
#   DROP - will be deleted from the font
# The default for unmentioned tables is FORBIDDEN
my %font_tables = (
    'cmap' => ['REQUIRED'],
    'head' => ['REQUIRED'],
    'hhea' => ['REQUIRED'],
    'hmtx' => ['REQUIRED'],
    'maxp' => ['REQUIRED'],
    'name' => ['REQUIRED'],
    'OS/2' => ['REQUIRED'],
    'post' => ['REQUIRED'],
    # TrueType outlines:
    'cvt ' => ['IGNORED'],
    'fpgm' => ['IGNORED'],
    'glyf' => ['IGNORED'],
    'loca' => ['OPTIONAL'],
    'prep' => ['OPTIONAL'],
    # PostScript outlines: (TODO: support these?)
    'CFF ' => ['FORBIDDEN'],
    'VORG' => ['FORBIDDEN'],
    # Bitmap glyphs:
    'EBDT' => ['FORBIDDEN'],
    'EBLC' => ['FORBIDDEN'],
    'EBSC' => ['FORBIDDEN'],
    # Advanced typographic tables:
    'BASE' => ['UNFINISHED'],
    'GDEF' => ['OPTIONAL'],
    'GPOS' => ['OPTIONAL'],
    'GSUB' => ['OPTIONAL'],
    'JSTF' => ['UNFINISHED'],
    # OpenType tables:
    'DSIG' => ['DROP'], # digital signature - don't need it here
    'gasp' => ['IGNORED'],
    'hdmx' => ['OPTIONAL'],
    'kern' => ['OPTIONAL'],
    'LTSH' => ['OPTIONAL'],
    'PCLT' => ['UNFINISHED'],
    'VDMX' => ['IGNORED'],
    'vhea' => ['UNFINISHED'],
    'vmtx' => ['UNFINISHED'],
    # SIL Graphite tables:
    'Feat' => ['DROP'],
    'Silf' => ['DROP'],
    'Sill' => ['DROP'],
    'Silt' => ['DROP'],
    'Glat' => ['DROP'],
    'Gloc' => ['DROP'],
    # FontForge tables:
    'PfEd' => ['DROP'],
    'FFTM' => ['DROP'],
    # Apple Advanced Typography tables:
    # (These get dropped because it's better to use cross-platform features instead)
    'feat' => ['DROP'],
    'morx' => ['DROP'],
    'prop' => ['DROP'],
    # Undocumented(?) extension for some kind of maths stuff (duh)
    'MATH' => ['DROP'],
);

sub check_tables {
    my ($self) = @_;
    my $font = $self->{font};

    my @tables = grep /^[^ ]...$/, sort keys %$font;
    for (@tables) {
        my $t = $font_tables{$_};
        if (not $t) {
            die "Uses unrecognised table '$_'\n";
        } else {
            my $status = $t->[0];
            if ($status eq 'FORBIDDEN') {
                die "Uses forbidden table '$_'\n";
            } elsif ($status eq 'UNFINISHED') {
                warn "Uses unhandled table '$_'\n";
            } elsif ($status eq 'DROP') {
                warn "Dropping table '$_'\n";
                delete $font->{$_};
            } elsif ($status eq 'OPTIONAL') {
            } elsif ($status eq 'IGNORED') {
            } elsif ($status eq 'REQUIRED') {
            } else {
                die "Invalid table status $status";
            }
        }
    }
    # TODO: check required tables are present
    # TODO: check TrueType or PostScript tables are present
}

sub read_tables {
    my ($self) = @_;
    my $font = $self->{font};

    # Read all the tables that will be needed in the future.
    # (In particular, read them before modifying numGlyphs,
    # beacuse they often depend on that value.)
    for (qw(
        cmap hmtx name OS/2 post
        glyf loca
        BASE GDEF GPOS GSUB JSTF
        hdmx kern LTSH
    )) {
        $font->{$_}->read if $font->{$_};
    }
}

=pod
# Return true if it's possible for the GSUB table to ever apply,
# given the restricted list of wanted glyphs
sub gsub_can_match {
    my ($self, $lookup, $sub) = @_;

    for (keys %{$sub->{COVERAGE}{val}}) {
        return 0 if not $self->{wanted_glyphs}{$_};
    }

    if ($sub->{MATCH_TYPE}) {
        if ($sub->{MATCH_TYPE} eq 'g') {
            # RULES->MATCH/PRE/POST are arrays of glyphs that must all match
            for (@{$sub->{RULES}}) {
                for (@$_) {
                    for my $c (qw(MATCH PRE POST)) {
                        next unless $_->{$c};
                        for (@{$_->{$c}}) {
                            return 0 if not $self->{wanted_glyphs}{$_};
                        }
                    }
                }
            }
        } elsif ($sub->{MATCH_TYPE} eq 'o') {
            # RULES->MATCH/PRE/POST are arrays of coverage tables,
            # and at least one glyph from each table must match
            die unless @{$sub->{RULES}} == 1;
            die unless @{$sub->{RULES}[0]} == 1;
            for my $c (qw(MATCH PRE POST)) {
                next unless $sub->{RULES}[0][0]{$c};
                for (@{$sub->{RULES}[0][0]{$c}}) {
                    my $matched = 0;
                    for (keys %{$_->{val}}) {
                        if ($self->{wanted_glyphs}{$_}) {
                            $matched = 1;
                            last;
                        }
                    }
                    return 0 if not $matched;
                }
            }
        }
    }

    # TODO: should look at $sub->{CLASS, PRE_CLASS, POST_CLASS}
    # and if all RULEs refer to at least one class that contains a
    # unwanted glyph, then reject this subtable.
    # But I haven't bothered with that yet, so conservatively
    # accept this subtable instead.

    return 1;
}
=cut

sub find_codepoint_glyph_mappings {
    my ($self) = @_;
    my $font = $self->{font};

    # Find the glyph->codepoint mappings

    my %glyphs;
    for my $table (@{$font->{cmap}{Tables}}) {
        for my $cp (keys %{$table->{val}}) {
            if (not (
                $table->{Platform} == 0 # Unicode
                or ($table->{Platform} == 3 and # Windows
                    ($table->{Encoding} == 1 or # Unicode BMP
                     $table->{Encoding} == 10)) # Unicode full
                or ($table->{Platform} == 1 # Mac
                    and $table->{Encoding} == 0) # "Roman" (assume it's Latin-1)
            )) {
                # This table might not map directly onto Unicode codepoints,
                # so warn about it
                warn "Unrecognised cmap table type (platform $table->{Platform}, encoding $table->{Encoding})\n";
            }

            my $g = $table->{val}{$cp};
            $glyphs{$g}{$cp} = 1;
        }
    }
    $self->{glyphs} = \%glyphs;
}

sub expand_wanted_chars {
    my ($self, $chars) = @_;
    # OS X browsers (via ATSUI?) appear to convert text into
    # NFC before rendering it.
    # So input like "i{combining grave}" is converted to "{i grave}"
    # before it's even passed to the font's substitution tables.
    # So if @chars contains i and {combining grave}, then we have to
    # add {i grave} because that might get used.
    #
    # So... Decompose all the input characters. Then, add any other character
    # which can be decomposed into a subset of those characters.

    if (0) {
        my %cs = map { ord $_ => 1 } split '', $chars;
        return %cs;
    }

    my @cs = split '', ($chars . Unicode::Normalize::NFD($chars));
    my %cs = map { ord $_ => 1 } @cs;
    require Font::Subsetter::NormalizationData;
    for my $c (@Font::Subsetter::NormalizationData::data) {
        # Skip this if we've already got the composed character
        next if $cs{$c->[0]};
        # Skip this if we don't have all the decomposed characters
        next if grep !$cs{$_}, @{$c}[1..$#$c];
        # Otherwise we want the composed character
        $cs{$c->[0]} = 1;
    }
    return %cs;
}

sub find_wanted_glyphs {
    my ($self, $chars) = @_;
    my $font = $self->{font};

    my %wanted_chars = $self->expand_wanted_chars($chars);
    $self->{wanted_glyphs} = {};

    $self->{wanted_glyphs}{0} = 1; # always have .notdef
    $self->{wanted_glyphs}{1} = 1; # always have .null
    $self->{wanted_glyphs}{2} = 1; # always have CR
    $self->{wanted_glyphs}{3} = 1; # always have space
    # TODO: is that necessarily correct, per http://www.microsoft.com/typography/otspec/recom.htm ?
    # (Also follow other recs in there)

    # We want any glyphs used directly by any characters we want
    for my $gid (keys %{$self->{glyphs}}) {
        for my $cp (keys %{$self->{glyphs}{$gid}}) {
            $self->{wanted_glyphs}{$gid} = 1 if $wanted_chars{$cp};
        }
    }

    # Iteratively find new glyphs, until convergence
    my @newly_wanted_glyphs = keys %{$self->{wanted_glyphs}};
    while (@newly_wanted_glyphs) {
        my @new_glyphs;

        if ($font->{GSUB}) {

            # Handle ligatures and similar things
            # (e.g. if we want 'f' and 'i', we want the 'fi' ligature too)
            # (NOTE: a lot of this code is duplicating the form of
            # fix_gsub, so they ought to be kept roughly in sync)
            #
            # TODO: There's probably loads of bugs in here, so it
            # should be checked and tested more

            for my $lookup (@{$font->{GSUB}{LOOKUP}}) {
                for my $sub (@{$lookup->{SUB}}) {
                 
                    # Handle the glyph-delta case
                    if ($sub->{ACTION_TYPE} eq 'o') {
                        my $adj = $sub->{ADJUST};
                        if ($adj >= 32768) { $adj -= 65536 } # fix Font::TTF::Bug (http://rt.cpan.org/Ticket/Display.html?id=42727)
                        my @covs = $self->coverage_array($sub->{COVERAGE});
                        for (@covs) {
                            # If we want the coveraged glyph, we also want
                            # that glyph plus delta
                            if ($self->{wanted_glyphs}{$_}) {
                                my $new = $_ + $adj;
                                next if $self->{wanted_glyphs}{$new};
                                push @new_glyphs, $new;
                                $self->{wanted_glyphs}{$new} = 1;
                            }
                        }
                        next;
                    }

                    # Collect the rules which might match initially something
                    my @rulesets;
                    if ($sub->{RULES}) {
                        if (($lookup->{TYPE} == 5 or $lookup->{TYPE} == 6)
                            and $sub->{FORMAT} == 2) {
                            # RULES corresponds to class values
                            # TODO: ought to filter this by classes that contain wanted glyphs
                            push @rulesets, @{$sub->{RULES}};
                        } elsif (($lookup->{TYPE} == 5 or $lookup->{TYPE} == 6)
                            and $sub->{FORMAT} == 3) {
                            # COVERAGE is empty; accept all the RULEs, and
                            # we'll look inside their MATCHes later
                            push @rulesets, @{$sub->{RULES}};
                        } else {
                            # COVERAGE lists glyphs, and there's a RULE for
                            # each, so extract the RULEs for wanted COVERAGE
                            # values
                            my @covs = $self->coverage_array($sub->{COVERAGE});
                            die unless @{$sub->{RULES}} == @covs;
                            for my $i (0..$#covs) {
                                if ($self->{wanted_glyphs}{$covs[$i]}) {
                                    push @rulesets, $sub->{RULES}[$i];
                                }
                            }
                        }
                    }

                    # Collect the rules whose MATCH matches
                    my @rules;
                    RULE: for my $rule (map @$_, @rulesets) {
                        if (not defined $sub->{MATCH_TYPE}) {
                            # No extra matching other than COVERAGE,
                            # so just accept this rule
                        } elsif ($sub->{MATCH_TYPE} eq 'g') {
                            # RULES->MATCH/PRE/POST are arrays of glyphs that must all match
                            for my $c (qw(MATCH PRE POST)) {
                                next unless $rule->{$c};
                                next RULE if grep { not $self->{wanted_glyphs}{$_} } @{$rule->{$c}};
                            }
                        } elsif ($sub->{MATCH_TYPE} eq 'o') {
                            # RULES->MATCH/PRE/POST are arrays of coverage tables,
                            # and at least one glyph from each table must match
                            die unless @{$sub->{RULES}} == 1;
                            die unless @{$sub->{RULES}[0]} == 1;
                            for my $c (qw(MATCH PRE POST)) {
                                next unless $sub->{RULES}[0][0]{$c};
                                for (@{$sub->{RULES}[0][0]{$c}}) {
                                    my $matched = 0;
                                    for (keys %{$_->{val}}) {
                                        if ($self->{wanted_glyphs}{$_}) {
                                            $matched = 1;
                                            last;
                                        }
                                    }
                                    next RULE if not $matched;
                                }
                            }
                        } elsif ($sub->{MATCH_TYPE} eq 'c') {
                            # TODO: only includes rules using classes that contain
                            # wanted glyphs.
                            # For now, just conservatively accept everything.
                        } else {
                            die "Invalid MATCH_TYPE";
                        }
                        push @rules, $rule;
                    }

                    # Find the glyphs in the relevant actions
                    for my $rule (@rules) {
                        if ($sub->{ACTION_TYPE} eq 'g') {
                            die unless $rule->{ACTION};
                            for my $new (@{$rule->{ACTION}}) {
                                next if $self->{wanted_glyphs}{$new};
                                push @new_glyphs, $new;
                                $self->{wanted_glyphs}{$new} = 1;
#                                warn "adding $new";
                            }
                        } elsif ($sub->{ACTION_TYPE} eq 'l') {
                            # do nothing - this is just a lookup to run some other rules
                        } elsif ($sub->{ACTION_TYPE} eq 'a') {
                            # do nothing - we don't want the alternative glyphs
                        } else {
                            die "Invalid ACTION_TYPE";
                        }
                    }
                }
            }
        }

        if ($font->{loca}) {
            # If we want a composite glyph, we want all of its
            # component glyphs too
            # (e.g. &aacute; is the 'a' glyph plus the acute glyph):
            for my $gid (@newly_wanted_glyphs) {
                my $glyph = $font->{loca}{glyphs}[$gid];
                next unless $glyph;
                $glyph->read;
                next unless $glyph->{numberOfContours} == -1;
                $glyph->read_dat;
                for (@{$glyph->{comps}}) {
                    next if $self->{wanted_glyphs}{$_->{glyph}};
                    push @new_glyphs, $_->{glyph};
                    $self->{wanted_glyphs}{$_->{glyph}} = 1;
                }
                $glyph->update;
            }
        }

        @newly_wanted_glyphs = @new_glyphs;
    }

}

sub update_classdef_table {
    my ($self, $table) = @_;
    die "Expected table" if not $table;
    die "Expected classdef" if $table->{cover};
    my @vals;
    for my $gid (keys %{$table->{val}}) {
        next if not $self->{wanted_glyphs}{$gid};
        my $v = $table->{val}{$gid};
        push @vals, $self->{glyph_id_old_to_new}{$gid}, $v;
    }
    my $ret = new Font::TTF::Coverage(0, @vals);
    # Font::TTF bug (http://rt.cpan.org/Ticket/Display.html?id=42716):
    # 'max' is not set by new(), so do it manually:
    my $max = 0;
    for (values %{$ret->{val}}) { $max = $_ if $_ > $max }
    $ret->{max} = $max;
    return $ret;
}

# Returns a map such that map[old_class_value] = new_class_value
# (or undef if the class is removed)
# This differs from update_classdef_table in that it can
# reorder and optimise the class ids
sub update_mapped_classdef_table {
    my ($self, $table) = @_;
    die "Expected table" if not $table;
    die "Expected classdef" if $table->{cover};
    my @vals;
    my %used_classes;
    $used_classes{0} = 1; # 0 is implicitly in every classdef
    for my $gid (keys %{$table->{val}}) {
        next if not $self->{wanted_glyphs}{$gid};
        my $v = $table->{val}{$gid};
        push @vals, $self->{glyph_id_old_to_new}{$gid}, $v;
        $used_classes{$v} = 1;
    }

    my @map_new_to_old = sort { $a <=> $b } keys %used_classes;
    my @map_old_to_new;
    $map_old_to_new[$map_new_to_old[$_]] = $_ for 0..$#map_new_to_old;

    # Update the class numbers
    for (0..@vals/2-1) {
        $vals[$_*2+1] = $map_old_to_new[$vals[$_*2+1]];
    }

    my $ret = new Font::TTF::Coverage(0, @vals);
    # Font::TTF bug (http://rt.cpan.org/Ticket/Display.html?id=42716):
    # 'max' is not set by new(), so do it manually:
    my $max = 0;
    for (values %{$ret->{val}}) { $max = $_ if $_ > $max }
    $ret->{max} = $max;
    return ($ret, \@map_old_to_new);
}

# Removes unwanted glyphs from a coverage table, for
# cases where nobody else is referring to indexes in this table
sub update_coverage_table {
    my ($self, $table) = @_;
    die "Expected table" if not $table;
    die "Expected cover" if not $table->{cover};
    my @vals = keys %{$table->{val}};
    @vals = grep $self->{wanted_glyphs}{$_}, @vals;
    @vals = sort { $a <=> $b } @vals;
    @vals = map $self->{glyph_id_old_to_new}{$_}, @vals;
    return new Font::TTF::Coverage(1, @vals);
}

# Returns a map such that map[new_coverage_index] = old_coverage_index
sub update_mapped_coverage_table {
    my ($self, $table) = @_;
    die "Expected table" if not $table;
    die "Expected coverage" if not $table->{cover};

    my @map;
    my @new_vals;
    # Get the covered values (in order)
    my @vals = $self->coverage_array($table);
    for my $i (0..$#vals) {
        # Create a new list of all the wanted values
        if ($self->{wanted_glyphs}{$vals[$i]}) {
            push @new_vals, $self->{glyph_id_old_to_new}{$vals[$i]};
            push @map, $i;
        }
    }
    return (new Font::TTF::Coverage(1, @new_vals), @map);
}

sub coverage_array {
    my ($self, $table) = @_;
    Carp::confess "Expected table" if not $table;
    return sort { $table->{val}{$a} <=> $table->{val}{$b} } keys %{$table->{val}};
}

sub empty_coverage {
    my ($self, $table) = @_;
    Carp::confess "Expected table" if not $table;
    return 1 if not $table->{val};
    return 1 if not keys %{$table->{val}};
    return 0;
}

# Update the loca table to delete unwanted glyphs.
# Must be called before all the other fix_* methods.
sub remove_unwanted_glyphs {
    my ($self) = @_;
    my $font = $self->{font};

    return unless $font->{loca};

    my %glyph_id_old_to_new;
    my %glyph_id_new_to_old;

    my $glyphs = $font->{loca}{glyphs};
    my @new_glyphs;
    for my $i (0..$#$glyphs) {
        if ($self->{wanted_glyphs}{$i}) {
            push @new_glyphs, $glyphs->[$i];
            $glyph_id_old_to_new{$i} = $#new_glyphs;
            $glyph_id_new_to_old{$#new_glyphs} = $i;
        }
    }
    $font->{loca}{glyphs} = \@new_glyphs;
    $font->{maxp}{numGlyphs} = scalar @new_glyphs;

    $self->{glyph_id_old_to_new} = \%glyph_id_old_to_new;
    $self->{glyph_id_new_to_old} = \%glyph_id_new_to_old;
}


sub fix_cmap {
    my ($self) = @_;
    my $font = $self->{font};

    # Delete mappings for unwanted glyphs

    for my $table (@{$font->{cmap}{Tables}}) {
        # (Already warned about unrecognised table types
        # in find_codepoint_glyph_mappings)
        my %new_vals;
        for my $cp (keys %{$table->{val}}) {
            my $gid = $table->{val}{$cp};
            if ($self->{wanted_glyphs}{$gid}) {
                $new_vals{$cp} = $self->{glyph_id_old_to_new}{$gid};
            }
        }
        $table->{val} = \%new_vals;
        if ($table->{Format} == 0) {
            @{$table->{val}}{0..255} = map { defined($_) ? $_ : 0 } @{$table->{val}}{0..255};
        }
    }
}

sub fix_head {
    # TODO: Should think about:
    #   created
    #   modified
    #   xMin (depends on glyph data)
    #   yMin (depends on glyph data)
    #   xMax (depends on glyph data)
    #   yMax (depends on glyph data)
}

sub fix_hhea {
    # TODO: Should think about:
    #   advanceWidthMax (depends on hmtx)
    #   minLeftSideBearing (depends on hmtx)
    #   minRightSideBearing (depends on hmtx)
    #   xMaxExtent (depends on hmtx)
}

sub fix_hmtx {
    my ($self) = @_;
    my $font = $self->{font};

    # Map the advance/lsb arrays from old to new glyph ids
    my @new_advances;
    my @new_lsbs;
    for my $gid (0..$font->{maxp}{numGlyphs}-1) {
        push @new_advances, $font->{hmtx}{advance}[$self->{glyph_id_new_to_old}{$gid}];
        push @new_lsbs, $font->{hmtx}{lsb}[$self->{glyph_id_new_to_old}{$gid}];
    }
    $font->{hmtx}{advance} = \@new_advances;
    $font->{hmtx}{lsb} = \@new_lsbs;
}

sub fix_maxp { # Must come after loca, prep, fpgm
    my ($self) = @_;
    my $font = $self->{font};

    # Update some of the 'max' values that Font::TTF
    # is capable of updating
    $font->{maxp}->update;
}

sub fix_os_2 { # Must come after cmap, hmtx, hhea, GPOS, GSUB
    my ($self) = @_;
    my $font = $self->{font};

    # Update some of the metric values that Font::TTF
    # is capable of updating
    $font->{'OS/2'}->update;

    if ($font->{'OS/2'}{Version} >= 2) {
        # TODO: handle cases where these are non-default
        warn "Unexpected defaultChar $font->{'OS/2'}{defaultChar}\n"
            unless $font->{'OS/2'}{defaultChar} == 0;
        warn "Unexpected breakChar $font->{'OS/2'}{breakChar}\n"
            unless $font->{'OS/2'}{breakChar} == 0x20;
    }
}

sub fix_post {
    my ($self) = @_;
    my $font = $self->{font};

    # Update PostScript name mappings for new glyph ids
    my @new_vals;
    for my $gid (0..$font->{maxp}{numGlyphs}-1) {
        push @new_vals, $font->{post}{VAL}[$self->{glyph_id_new_to_old}{$gid}];
    }
    $font->{post}{VAL} = \@new_vals;
}




sub fix_loca {
    my ($self) = @_;
    my $font = $self->{font};

    # remove_unwanted_glyphs has already removed some
    # of the glyph data from this table

    # Update references inside composite glyphs
    for my $glyph (@{$font->{loca}{glyphs}}) {
        next unless $glyph;
        $glyph->read;
        next unless $glyph->{numberOfContours} == -1;
        $glyph->read_dat;
        for (@{$glyph->{comps}}) {
            # (find_unwanted_glyphs guarantees that the
            # component glyphs will be present)
            $_->{glyph} = $self->{glyph_id_old_to_new}{$_->{glyph}};
        }
    }
}



sub fix_gdef {
    my ($self) = @_;
    my $font = $self->{font};

    if ($font->{GDEF}{GLYPH}) {
        $font->{GDEF}{GLYPH} = $self->update_classdef_table($font->{GDEF}{GLYPH});
        if ($self->empty_coverage($font->{GDEF}{GLYPH})) {
            delete $font->{GDEF}{GLYPH};
        }
    }

    if ($font->{GDEF}{MARKS}) {
        $font->{GDEF}{MARKS} = $self->update_classdef_table($font->{GDEF}{MARKS});
        if ($self->empty_coverage($font->{GDEF}{MARKS})) {
            delete $font->{GDEF}{MARKS};
        }
    }

    if ($font->{GDEF}{ATTACH}) {
        die "TODO" if $font->{GDEF}{ATTACH}{POINTS};
        $font->{GDEF}{ATTACH}{COVERAGE} = $self->update_coverage_table($font->{GDEF}{ATTACH}{COVERAGE});
        if ($self->empty_coverage($font->{GDEF}{ATTACH}{COVERAGE})) {
            delete $font->{GDEF}{ATTACH};
        }
    }

    if ($font->{GDEF}{LIG}) {

        if ($font->{GDEF}{LIG}{LIGS}) {
            die "GDEF LIG LIGS != COVERAGE" if
                @{$font->{GDEF}{LIG}{LIGS}} != keys %{$font->{GDEF}{LIG}{COVERAGE}{val}};

            my @coverage_map;
            ($font->{GDEF}{LIG}{COVERAGE}, @coverage_map) = $self->update_mapped_coverage_table($font->{GDEF}{LIG}{COVERAGE});
            $font->{GDEF}{LIG}{LIGS} = [ map $font->{GDEF}{LIG}{LIGS}[$_], @coverage_map ];

        } else {
            $font->{GDEF}{LIG}{COVERAGE} = $self->update_coverage_table($font->{GDEF}{LIG}{COVERAGE});
        }

        if ($self->empty_coverage($font->{GDEF}{LIG}{COVERAGE})) {
            delete $font->{GDEF}{LIG};
        }
    }
 
}

sub fix_gpos {
    my ($self) = @_;
    my $font = $self->{font};

    my @lookups;
    my $lookup_id = 0;
    my %lookup_map;
    for my $lookup (@{$font->{GPOS}{LOOKUP}}) {
        my @subtables;
        for my $sub (@{$lookup->{SUB}}) {
            # There's always a COVERAGE here first.
            # (If it's empty, the client will skip the entire subtable,
            # so we could delete it entirely, but that would involve updating
            # the FEATURES->*->LOOKUPS lists too, so don't do that yet.)
            #
            # The rest depends on Type:
            # 
            # Lookup Type 1 (Single Adjustment Positioning Subtable):
            # Format 1: Just COVERAGE, applies same value to all
            # Format 2: Just COVERAGE, RULES[n] gives value for each
            #
            # Lookup Type 2 (Pair Adjustment Positioning Subtable):
            # Format 1: COVERAGE gives first glyph, RULES[n][m]{MATCH}[0] gives second glyph
            # Format 2: COVERAGE gives first glyph, CLASS gives first glyph class, MATCH[0] gives second glyph class
            #
            # Lookup Type 3 (Cursive Attachment Positioning Subtable):
            # Format 1: Just COVERAGE, RULES[n] gives value for each
            #
            # Lookup Type 4 (MarkToBase Attachment Positioning Subtable):
            # Format 1: MATCH[0] gives mark coverage, COVERAGE gives base coverage, MARKS[n] per mark, RULES[n] per base
            #
            # Lookup Type 5 (MarkToLigature Attachment Positioning Subtable):
            # Format 1: pretty much the same as 4, but s/base/ligature/
            #
            # Lookup Type 6 (MarkToMark Attachment Positioning Subtable):
            # Format 1: pretty much the same as 4, but s/base/mark/
            #
            # Lookup Type 7 (Contextual Positioning Subtables):
            # Format 1: COVERAGE gives first glyph, RULES[n][m]{MATCH}[o] gives next glyphs
            # Format 2: COVERAGE gives first glyph, CLASS gives classes to glyphs, RULES[n] is per class
            # Format 3: COVERAGE absent, RULES[0][0]{MATCH}[o] gives glyph coverages
            #
            # Lookup Type 8 (Chaining Contextual Positioning Subtable):
            # Format 1: COVERAGE gives first glyph, RULES[n][m]{PRE/MATCH/POST} give context glyphs
            # Format 2: COVERAGE gives first glyph, PRE_CLASS/CLASS/POST_CLASS give classes
            # Format 3: COVERAGE absent, RULES[0][0]{PRE/MATCH/POST}[o] give coverages
            #
            # Lookup Type 9 (Extension Positioning):
            # Blah

            # TODO: I'm not at all confident that this is all correct --
            # really ought to test it with real data...

#            warn "$lookup->{TYPE} $sub->{FORMAT}";

            die if $lookup->{TYPE} >= 9;

            # Update the COVERAGE table, and remember some mapping
            # information to update things that refer to the table
            my @coverage_map;
            my $old_coverage_count;
            if ($sub->{COVERAGE}) {
                $old_coverage_count = scalar keys %{$sub->{COVERAGE}{val}};
                ($sub->{COVERAGE}, @coverage_map) = $self->update_mapped_coverage_table($sub->{COVERAGE});

                # If there's no coverage left, then drop this subtable
                next if $self->empty_coverage($sub->{COVERAGE});
            }

            if ($sub->{RULES} and not
                    # Skip cases where RULES is indexed by CLASS, not COVERAGE
                    (($lookup->{TYPE} == 2 or
                      $lookup->{TYPE} == 7 or
                      $lookup->{TYPE} == 8)
                        and $sub->{FORMAT} == 2)
                ) {
                # There's a RULES array per COVERAGE entry, so
                # shuffle them around to match the new COVERAGE
                die unless @{$sub->{RULES}} == $old_coverage_count;
                $sub->{RULES} = [ map $sub->{RULES}[$_], @coverage_map ];
            }

            if (not defined $sub->{MATCH_TYPE} or $sub->{MATCH_TYPE} eq 'g') {
                if ($sub->{MATCH}) {
                    die unless @{$sub->{MATCH}} == 1;
                    die unless $sub->{MARKS};
                    die unless @{$sub->{MARKS}} == keys %{$sub->{MATCH}[0]{val}};
                    my @match_map;
                    ($sub->{MATCH}[0], @match_map) = $self->update_mapped_coverage_table($sub->{MATCH}[0]);

                    # If there's no coverage left, then drop this subtable
                    next if $self->empty_coverage($sub->{MATCH}[0]);

                    # Update MARKS to correspond to the new MATCH coverage
                    $sub->{MARKS} = [ map $sub->{MARKS}[$_], @match_map ];
                }
                # RULES->MATCH is an array of glyphs, so translate them all
                for (@{$sub->{RULES}}) {
                    for (@$_) {
                        $_->{MATCH} = [ map $self->{glyph_id_old_to_new}{$_},
                            grep $self->{wanted_glyphs}{$_}, @{$_->{MATCH}} ];
                    }
                }
            } elsif ($sub->{MATCH_TYPE}) {
                if ($sub->{MATCH_TYPE} eq 'o') {
                    # RULES->MATCH/PRE/POST are arrays of coverage tables, so translate them all
                    die unless @{$sub->{RULES}} == 1;
                    die unless @{$sub->{RULES}[0]} == 1;
                    my $r = $sub->{RULES}[0][0];
                    for my $c (qw(MATCH PRE POST)) {
                        $r->{$c} = [ map $self->update_coverage_table($_), @{$r->{$c}} ] if $r->{$c};
                    }
                } elsif ($sub->{MATCH_TYPE} eq 'c') {
                    die "Didn't expect any rule matches" if grep $_->{MATCH}, map @$_, @{$sub->{RULES}};

                    # Update MATCH classdef
                    die unless @{$sub->{MATCH}} == 1;
                    $sub->{MATCH}[0] = $self->update_classdef_table($sub->{MATCH}[0]);

                } else {
                    die "Invalid MATCH_TYPE";
                }
            }

            # Update some class tables
            for my $c (qw(CLASS PRE_CLASS POST_CLASS)) {
                $sub->{$c} = $self->update_classdef_table($sub->{$c}) if $sub->{$c};
            }

            push @subtables, $sub;
        }

        # Only keep lookups that have some subtables
        if (@subtables) {
            $lookup->{SUB} = \@subtables;
            push @lookups, $lookup;
            $lookup_map{$lookup_id} = $#lookups;
        }
        ++$lookup_id;
    }

    $font->{GPOS}{LOOKUP} = \@lookups;

    # Update the FEATURES array's lookup references
    for my $tag (@{$font->{GPOS}{FEATURES}{FEAT_TAGS}}) {
        my $feat = $font->{GPOS}{FEATURES}{$tag};
        $feat->{LOOKUPS} = [ map { exists $lookup_map{$_} ? ($lookup_map{$_}) : () } @{$feat->{LOOKUPS}} ];
    }
}

sub fix_gsub {
    my ($self) = @_;
    my $font = $self->{font};

    for my $lookup (@{$font->{GSUB}{LOOKUP}}) {
        my @subtables;
        for my $sub (@{$lookup->{SUB}}) {
            # There's always a COVERAGE here first.
            # (If it's empty, the client will skip the entire subtable,
            # so we could delete it entirely, but that would involve updating
            # the FEATURES->*->LOOKUPS lists and Contextual subtable indexes
            # too, so don't do that yet.)
            #
            # The rest depends on Type:
            # 
            # Lookup Type 1 (Single Substitution Subtable):
            # Format 1: Just COVERAGE, and ADJUST gives glyph id delta
            # Format 2: Just COVERAGE, then RULES[n]{ACTION}[0] gives replacement glyph for each
            #
            # Lookup Type 2 (Multiple Substitution Subtable):
            # Format 1: Just COVERAGE, then RULES[n]{ACTION} gives replacement glyphs (must be at least 1)
            #
            # Lookup Type 3 (Alternate Substitution Subtable):
            # Format 1: Just COVERAGE, then RULES[n]{ACTION} gives alternate glyphs
            # [This can just be deleted since we have no way to use those glyphs]
            #
            # Lookup Type 4 (Ligature Substitution Subtable):
            # Format 1: COVERAGE gives first glyph, RULES[n]{MATCH}[m] gives next glyphs to match, RULES[n]{ACTION}[0] gives replacement glyph
            #
            # Lookup Type 5 (Contextual Substitution Subtable):
            # Format *: like type 7 in GPOS, but ACTION gives indexes into GSUB{LOOKUP}
            #
            # Lookup Type 6 (Chaining Contextual Substitution Subtable):
            # Format *: like type 8 in GPOS, but ACTION gives indexes into GSUB{LOOKUP}
            #
            # Lookup Type 7 (Extension Substitution):
            # Blah

            die if $lookup->{TYPE} >= 7;

            # If it's impossible for this subtable to match, then
            # we want to delete the whole thing.
            # But that messes up index numbers so it's hard and
            # I'm not going to bother.
            #if (not $self->gsub_can_match($lookup, $sub)) {
            #    # ...
            #}

            # Update the COVERAGE table, and remember some mapping
            # information to update things that refer to the table
            my @coverage_map;
            my $old_coverage_count;
            if ($sub->{COVERAGE}) {
                $old_coverage_count = scalar keys %{$sub->{COVERAGE}{val}};
                ($sub->{COVERAGE}, @coverage_map) = $self->update_mapped_coverage_table($sub->{COVERAGE});

                # If there's no coverage left, then drop this subtable
                next if $self->empty_coverage($sub->{COVERAGE});
            }

            if ($sub->{ACTION_TYPE} eq 'o') {;
                my $adj = $sub->{ADJUST};
                if ($adj >= 32768) { $adj -= 65536 } # fix Font::TTF::Bug (http://rt.cpan.org/Ticket/Display.html?id=42727)
                my @covs = $self->coverage_array($sub->{COVERAGE});
                if (@covs == 0) {
                    # Nothing's covered, but deleting this whole subtable is
                    # non-trivial so just zero it out
                    $sub->{ADJUST} = 0;
                } elsif (@covs == 1) {
                    my $gid_base = $covs[0];
                    my $old_gid_base = $self->{glyph_id_new_to_old}{$gid_base};
                    my $old_gid = $old_gid_base + $adj;
                    $sub->{ADJUST} = $self->{glyph_id_old_to_new}{$old_gid} - $gid_base;
                } else {
                    # The glyphs are probably all reordered, so we can't just
                    # adjust ADJUST.
                    # So switch this to a format 2 table:
                    $sub->{FORMAT} = 2;
                    $sub->{ACTION_TYPE} = 'g';
                    delete $sub->{ADJUST};
                    my @gids;
                    for (@covs) {
                        push @gids, $self->{glyph_id_old_to_new}{$self->{glyph_id_new_to_old}{$_} + $adj};
                    }
                    $sub->{RULES} = [ map [{ACTION => [$_]}], @gids ];
                }
                # Don't bother with the rest of this loop, since we've
                # done everything that's needed
                next;
            }
            die if $sub->{ADJUST};

            if ($sub->{RULES} and not
                    # Skip cases where RULES is indexed by CLASS, not COVERAGE,
                    # and cases where there's no COVERAGE at all
                    (($lookup->{TYPE} == 5 or $lookup->{TYPE} == 6)
                        and ($sub->{FORMAT} == 2 or $sub->{FORMAT} == 3))
                ) {
                # There's a RULES array per COVERAGE entry, so
                # shuffle them around to match the new COVERAGE
                die unless @{$sub->{RULES}} == $old_coverage_count;
                $sub->{RULES} = [ map $sub->{RULES}[$_], @coverage_map ];
            }

            # TODO: refactor
            if ($sub->{MATCH_TYPE}) {
                # Fix all the glyph indexes
                if ($sub->{MATCH_TYPE} eq 'g') {
                    # RULES->MATCH/PRE/POST are arrays of glyphs, so translate them all,
                    # and if they rely on any unwanted glyphs then drop the rule entirely
                    for my $i (0..$#{$sub->{RULES}}) {
                        my $ruleset = $sub->{RULES}[$i];
                        my @rules;
                        RULE: for my $rule (@$ruleset) {
                            for my $c (qw(MATCH PRE POST)) {
                                next unless $rule->{$c};
                                next RULE if grep { not $self->{wanted_glyphs}{$_} } @{$rule->{$c}};
                                $rule->{$c} = [ map $self->{glyph_id_old_to_new}{$_}, @{$rule->{$c}} ]
                            }
                            push @rules, $rule;
                        }
                        if (not @rules) {
                            # XXX: This is a really horrid hack.
                            # The proper solution is to delete the ruleset,
                            # and adjust COVERAGE to match.
                            warn "XXX";
                            push @rules, { ACTION => [0], MATCH => [-1] };
                        }
                        $sub->{RULES}[$i] = \@rules;
                    }
                } elsif ($sub->{MATCH_TYPE} eq 'o') {
                    # RULES->MATCH/PRE/POST are arrays of coverage tables, so translate them all
                    die unless @{$sub->{RULES}} == 1;
                    die unless @{$sub->{RULES}[0]} == 1;
                    my $r = $sub->{RULES}[0][0];
                    for my $c (qw(MATCH PRE POST)) {
                        $r->{$c} = [ map $self->update_coverage_table($_), @{$r->{$c}} ] if $r->{$c};
                    }
                } elsif ($sub->{MATCH_TYPE} eq 'c') {
                    # RULES refers to class values, which haven't changed at all,
                    # so we don't need to update those values
                } else {
                    die "Invalid MATCH_TYPE";
                }
            }

            my %class_maps;
            for my $c (qw(CLASS PRE_CLASS POST_CLASS)) {
                ($sub->{$c}, $class_maps{$c}) = $self->update_mapped_classdef_table($sub->{$c}) if $sub->{$c};
            }


            if ($sub->{MATCH_TYPE} and $sub->{MATCH_TYPE} eq 'c') {
                # To make things work in Pango, we need to change all the
                # class numbers so there aren't gaps:
                my %classes = (
                    MATCH => 'CLASS',
                    PRE => 'PRE_CLASS',
                    POST => 'POST_CLASS',
                );
                my @rules;
                for my $rule (@{$sub->{RULES}}) {
                    my @chains;
                    CHAIN: for my $chain (@$rule) {
                        for my $c (qw(MATCH PRE POST)) {
                            next unless $chain->{$c};
                            my $map = $class_maps{$classes{$c}} or die "Got a $c but no $classes{$c}";
                            # If any of the values are for a class that no longer has
                            # any entries, we should drop this whole chain because
                            # there's no chance it's going to match
                            next CHAIN if grep { not defined $map->[$_] } @{$chain->{$c}};
                            # Otherwise just update the class numbers
                            $chain->{$c} = [ map $map->[$_], @{$chain->{$c}} ];
                        }
                        push @chains, $chain;
                    }
                    push @rules, \@chains;
                }
                $sub->{RULES} = \@rules;
                # If all the rules are empty, drop this whole subtable (which maybe is
                # needed to avoid https://bugzilla.mozilla.org/show_bug.cgi?id=475242 ?)
                next if not grep @$_, @{$sub->{RULES}};
            }

            if ($sub->{ACTION_TYPE}) {
                if ($sub->{ACTION_TYPE} eq 'g') {
                    for (@{$sub->{RULES}}) {
                        for (@$_) {
                            $_->{ACTION} = [ map $self->{glyph_id_old_to_new}{$_},
                                grep $self->{wanted_glyphs}{$_}, @{$_->{ACTION}} ];
                        }
                    }
                } elsif ($sub->{ACTION_TYPE} eq 'l') {
                    # nothing to change here
                } elsif ($sub->{ACTION_TYPE} eq 'a') {
                    # We don't want to bother with alternate glyphs at all,
                    # so just delete everything.
                    # (We need to have empty rules, and can't just delete them
                    # entirely, else FontTools becomes unhappy.)
                    # (TODO: Maybe we do want alternate glyphs?
                    # If so, be sure to update find_wanted_glyphs too) 
                    for (@{$sub->{RULES}}) {
                        for (@$_) {
                            $_->{ACTION} = [];
                        }
                    }
                } elsif ($sub->{ACTION_TYPE} eq 'o') {
                    die "Should have handeld ACTION_TYPE o earlier";
                } else {
                    die "Invalid ACTION_TYPE";
                }
            }

            push @subtables, $sub;
        }
        $lookup->{SUB} = \@subtables;
    }

}

sub fix_hdmx {
    my ($self) = @_;
    my $font = $self->{font};

    for my $ppem (grep /^\d+$/, keys %{$font->{hdmx}}) {
        my @new_widths;
        for my $gid (0..$font->{maxp}{numGlyphs}-1) {
            push @new_widths, $font->{hdmx}{$ppem}[$self->{glyph_id_new_to_old}{$gid}];
        }
        $font->{hdmx}{$ppem} = \@new_widths;
    }
}

sub fix_kern {
    my ($self) = @_;
    my $font = $self->{font};

    # We don't handle version 1 kern tables yet, so just drop them entirely.
    # http://developer.apple.com/textfonts/TTRefMan/RM06/Chap6kern.html
    # https://bugzilla.mozilla.org/show_bug.cgi?id=487549
    if ($font->{kern}{Version} != 0) {
        warn "Unhandled kern table version $font->{kern}{Version}\n";
        delete $font->{kern};
        return;
    }

    for my $table (@{$font->{kern}{tables}}) {
        if ($table->{type} == 0) {
            my %kern;
            for my $l (keys %{$table->{kern}}) {
                next unless $self->{wanted_glyphs}{$l};
                for my $r (keys %{$table->{kern}{$l}}) {
                    next unless $self->{wanted_glyphs}{$r};
                    $kern{$self->{glyph_id_old_to_new}{$l}}{$self->{glyph_id_old_to_new}{$r}} = $table->{kern}{$l}{$r};
                }
            }
            $table->{kern} = \%kern;
        } elsif ($table->{type} == 2) {
            die "kern table type 2 not supported yet";
        } else {
            die "Invalid kern table type";
        }
    }
}

sub fix_ltsh {
    my ($self) = @_;
    my $font = $self->{font};

    my @glyphs;
    for my $gid (0..$font->{maxp}{numGlyphs}-1) {
        push @glyphs, $font->{LTSH}{glyphs}[$self->{glyph_id_new_to_old}{$gid}];
    }
    $font->{LTSH}{glyphs} = \@glyphs;
}

sub delete_copyright {
    my ($self) = @_;
    my $font = $self->{font};
    # XXX - shouldn't be deleting copyright text
    $font->{name}{strings}[0] = undef;
    $font->{name}{strings}[10] = undef;
    $font->{name}{strings}[13] = undef;
}

sub change_name {
    my ($self, $uid) = @_;
    my $font = $self->{font};

    for (1,3,4,6) {
    my $str = $font->{name}{strings}[$_];
    for my $plat (0..$#$str) {
        next unless $str->[$plat];
        for my $enc (0..$#{$str->[$plat]}) {
            next unless $str->[$plat][$enc];
            for my $lang (keys %{$str->[$plat][$enc]}) {
                next unless exists $str->[$plat][$enc]{$lang};
                $str->[$plat][$enc]{$lang} = "$uid - subset of " . $str->[$plat][$enc]{$lang};
            }
        }
    }
    }
}

sub new {
    my $class = shift;
    my $self = {};
    bless $self, $class;
    return $self;
}

sub subset {
    my ($self, $filename, $chars) = @_;

    my $uid = substr(sha1_hex("$filename $chars"), 0, 16);

    my $font = Font::TTF::Font->open($filename) or die "Failed to open $filename: $!";
    $self->{font} = $font;

    $self->check_tables;

    $self->{num_glyphs_old} = $font->{maxp}{numGlyphs};

    $self->read_tables;

    my $fsType = $font->{'OS/2'}{fsType};
    warn "fsType is $fsType\n" if $fsType != 0;

    $self->find_codepoint_glyph_mappings;
    $self->find_wanted_glyphs($chars);
    $self->remove_unwanted_glyphs;

    $self->fix_cmap;
    $self->fix_head;
    $self->fix_hhea;
    $self->fix_hmtx;
    # name: nothing to fix (though maybe could be optimised?)
    $self->fix_post;

    # cvt_: nothing to fix
    # fpgm: nothing to fix
    # glyf: just a stub, in Font::TTF
    $self->fix_loca;
    # prep: nothing to fix

    # BASE: TODO
    $self->fix_gdef if $font->{GDEF};
    $self->fix_gpos if $font->{GPOS};
    $self->fix_gsub if $font->{GSUB};
    # JSTF: TODO

    $self->fix_hdmx if $font->{hdmx};
    $self->fix_kern if $font->{kern};
    $self->fix_ltsh if $font->{LTSH};
    
    $self->fix_maxp; # Must come after loca, prep, fpgm
    $self->fix_os_2; # Must come after cmap, hmtx, hhea, GPOS, GSUB

    $self->change_name($uid);

#    print "# got glyphs @{$font->{post}{VAL}}\n";

    $self->{num_glyphs_new} = $font->{maxp}{numGlyphs};
}

sub num_glyphs_old {
    my ($self) = @_;
    return $self->{num_glyphs_old};
}

sub num_glyphs_new {
    my ($self) = @_;
    return $self->{num_glyphs_new};
}

sub glyph_names {
    my ($self) = @_;
    my $font = $self->{font};
    return @{$font->{post}{VAL}};
}

sub write {
    my ($self, $fh) = @_;
    my $font = $self->{font};
    $font->out($fh) or die $!;
}

sub release {
    my ($self) = @_;
    my $font = $self->{font};
    $font->release;
}

1;

