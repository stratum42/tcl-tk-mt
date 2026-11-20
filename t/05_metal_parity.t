#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

BEGIN {
    use_ok('Tcl::Tk::MT::Gfx');
}

if (!Tcl::Tk::MT::Gfx::backend_available('metal')) {
    plan skip_all => 'Metal backend not available on this host';
}

sub compare_rgba {
    my ($a, $b, $tol) = @_;
    my $n = length($a);
    die "length mismatch: $n vs " . length($b) if $n != length($b);
    my @ba = unpack('C*', $a);
    my @bb = unpack('C*', $b);
    my $max_delta = 0;
    my $within = 0;
    my $exact  = 0;
    for (my $i = 0; $i < $n; $i++) {
        my $d = abs($ba[$i] - $bb[$i]);
        $max_delta = $d if $d > $max_delta;
        $exact++  if $d == 0;
        $within++ if $d <= $tol;
    }
    return ($max_delta, 100.0 * $within / $n, 100.0 * $exact / $n);
}

my ($W, $H) = (128, 128);
my $s_sw  = Tcl::Tk::MT::Gfx::create_surface($W, $H, 'software', 1.0, 1);
my $s_mtl = Tcl::Tk::MT::Gfx::create_surface($W, $H, 'metal',    1.0, 1);
ok(defined $s_sw && defined $s_mtl, 'created software and metal headless surfaces');
is($s_mtl->backend_name(), 'metal', 'metal surface reports metal backend');

# -------------------------------------------------------------------------
# Tier 1: Exact match on integer non-AA fills + 1:1 RGBA8 texture blit
# -------------------------------------------------------------------------
{
    my $tex_bytes = '';
    for my $y (0 .. 15) {
        for my $x (0 .. 15) {
            $tex_bytes .= pack('C4', $x * 16, $y * 16, (($x + $y) * 8) & 255, 255);
        }
    }
    my $t_sw  = $s_sw->texture_create_rgba(16, 16, $tex_bytes);
    my $t_mtl = $s_mtl->texture_create_rgba(16, 16, $tex_bytes);
    ok($t_sw > 0 && $t_mtl > 0, 'created matching RGBA8 textures');

    my $sc_sw = Tcl::Tk::MT::Gfx::create_scene($W, $H);
    $sc_sw->set_clear_color(Tcl::Tk::MT::Gfx::rgba(20, 30, 40, 255), 1);
    my $r1 = $sc_sw->create_item('rectangle', [10, 10, 50, 40]);
    $sc_sw->set_fill($r1, Tcl::Tk::MT::Gfx::rgba(200, 50, 30, 255));
    $sc_sw->set_flags($r1, 0);
    my $r2 = $sc_sw->create_item('rectangle', [20, 60, 100, 100]);
    $sc_sw->set_fill($r2, Tcl::Tk::MT::Gfx::rgba(40, 190, 80, 255));
    $sc_sw->set_flags($r2, 0);
    my $im1 = $sc_sw->create_item('image', [70, 15]);
    $sc_sw->set_image($im1, $t_sw, 16, 16);

    my $sc_mtl = Tcl::Tk::MT::Gfx::create_scene($W, $H);
    $sc_mtl->set_clear_color(Tcl::Tk::MT::Gfx::rgba(20, 30, 40, 255), 1);
    my $mr1 = $sc_mtl->create_item('rectangle', [10, 10, 50, 40]);
    $sc_mtl->set_fill($mr1, Tcl::Tk::MT::Gfx::rgba(200, 50, 30, 255));
    $sc_mtl->set_flags($mr1, 0);
    my $mr2 = $sc_mtl->create_item('rectangle', [20, 60, 100, 100]);
    $sc_mtl->set_fill($mr2, Tcl::Tk::MT::Gfx::rgba(40, 190, 80, 255));
    $sc_mtl->set_flags($mr2, 0);
    my $mim1 = $sc_mtl->create_item('image', [70, 15]);
    $sc_mtl->set_image($mim1, $t_mtl, 16, 16);

    is($sc_sw->render($s_sw),   0, 'Tier 1 software render succeeded');
    is($sc_mtl->render($s_mtl), 0, 'Tier 1 metal render succeeded');

    my $b_sw  = $s_sw->readback_rgba();
    my $b_mtl = $s_mtl->readback_rgba();
    my ($max_d, $pct, $epct) = compare_rgba($b_sw, $b_mtl, 0);
    is($max_d, 0, sprintf('Tier 1 exact parity: max_delta=0 (exact=%.3f%%)', $epct));
    is($s_mtl->readback_sha256(), $s_sw->readback_sha256(),
       'Tier 1 SHA-256 bit-for-bit match between Metal and Software');

    $s_sw->texture_destroy($t_sw);
    $s_mtl->texture_destroy($t_mtl);
}

# -------------------------------------------------------------------------
# Tier 2: AA SDF shapes, polylines, polygons, instanced circles, R8 text
#         Requirement: max channel delta <= 2/255 and >= 99.9% match
# -------------------------------------------------------------------------
{
    my $build_scene = sub {
        my $sc = Tcl::Tk::MT::Gfx::create_scene($W, $H);
        $sc->set_clear_color(Tcl::Tk::MT::Gfx::rgba(15, 18, 24, 255), 1);

        my $rr = $sc->create_item('rectangle', [8, 8, 56, 44]);
        $sc->set_fill($rr, Tcl::Tk::MT::Gfx::rgba(60, 140, 220, 220));
        $sc->set_outline($rr, Tcl::Tk::MT::Gfx::rgba(255, 255, 255, 255));
        $sc->set_width($rr, 2.0);
        $sc->set_corner_radius($rr, 8.0);

        my $ov = $sc->create_item('oval', [66, 10, 118, 50]);
        $sc->set_fill($ov, Tcl::Tk::MT::Gfx::rgba(220, 120, 40, 200));
        $sc->set_outline($ov, Tcl::Tk::MT::Gfx::rgba(20, 30, 40, 255));
        $sc->set_width($ov, 1.5);

        my $ar = $sc->create_item('arc', [10, 56, 58, 104]);
        $sc->set_fill($ar, Tcl::Tk::MT::Gfx::rgba(50, 200, 90, 255));
        $sc->set_arc_angles($ar, 15, 230, 'pieslice');

        my $pl = $sc->create_item('line', [66, 60, 116, 60, 116, 86]);
        $sc->set_fill($pl, Tcl::Tk::MT::Gfx::rgba(255, 90, 180, 255));
        $sc->set_width($pl, 3.0);

        my @inst;
        for my $i (0 .. 15) {
            push @inst, 12 + ($i % 8) * 14, 110 + int($i / 8) * 10,
                 Tcl::Tk::MT::Gfx::rgba(100 + $i * 8, 220, 140, 255), 6;
        }
        $sc->create_instances(\@inst, 2, 1, 4);

        my $tx = $sc->create_item('text', [66, 94]);
        $sc->set_text($tx, 'Metal!', undef, 12);
        $sc->set_fill($tx, Tcl::Tk::MT::Gfx::rgba(255, 240, 120, 255));
        return $sc;
    };

    my $sc_sw  = $build_scene->();
    my $sc_mtl = $build_scene->();

    Tcl::Tk::MT::Gfx::reset_stats();
    is($sc_sw->render($s_sw),   0, 'Tier 2 software render succeeded');
    is($sc_mtl->render($s_mtl), 0, 'Tier 2 metal render succeeded');

    my $b_sw  = $s_sw->readback_rgba();
    my $b_mtl = $s_mtl->readback_rgba();
    my ($max_d, $pct, $epct) = compare_rgba($b_sw, $b_mtl, 2);

    cmp_ok($max_d, '<=', 2, sprintf('Tier 2 max channel delta <= 2 (got %d)', $max_d));
    cmp_ok($pct,   '>=', 99.9,
           sprintf('Tier 2 match >= 99.9%% within 2/255 (got %.3f%%, exact=%.3f%%)', $pct, $epct));

    my $st = Tcl::Tk::MT::Gfx::stats();
    is($st->{last_backend_name}, 'metal', 'stats last_backend_name is metal');
    cmp_ok($st->{offload_calls}, '>=', 1, 'stats offload_calls incremented for metal');
}

done_testing();
