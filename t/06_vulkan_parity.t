#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

BEGIN {
    use_ok('Tcl::Tk::MT::Gfx');
}

if (!Tcl::Tk::MT::Gfx::backend_available('vulkan')) {
    ok(1, 'vulkan probe returned 0 gracefully without crashing');
    done_testing();
    exit 0;
}

sub compare_rgba {
    my ($a, $b, $tol) = @_;
    my $n = length($a);
    die "length mismatch: $n vs " . length($b) if $n != length($b);
    my @ba = unpack('C*', $a);
    my @bb = unpack('C*', $b);
    my $max_delta = 0;
    my $within = 0;
    for (my $i = 0; $i < $n; $i++) {
        my $d = abs($ba[$i] - $bb[$i]);
        $max_delta = $d if $d > $max_delta;
        $within++ if $d <= $tol;
    }
    return ($max_delta, 100.0 * $within / $n);
}

my ($W, $H) = (128, 128);
my $s_sw = Tcl::Tk::MT::Gfx::create_surface($W, $H, 'software', 1.0, 1);
my $s_vk = Tcl::Tk::MT::Gfx::create_surface($W, $H, 'vulkan',   1.0, 1);
ok(defined $s_sw && defined $s_vk, 'created software and vulkan headless surfaces');
is($s_vk->backend_name(), 'vulkan', 'vulkan surface reports vulkan backend');

# Tier 1: Exact non-AA integer fills + RGBA8 blit
{
    my $tex_bytes = '';
    for my $y (0 .. 15) {
        for my $x (0 .. 15) {
            $tex_bytes .= pack('C4', $x * 16, $y * 16, (($x + $y) * 8) & 255, 255);
        }
    }
    my $t_sw = $s_sw->texture_create_rgba(16, 16, $tex_bytes);
    my $t_vk = $s_vk->texture_create_rgba(16, 16, $tex_bytes);

    my $make_t1 = sub {
        my ($tid) = @_;
        my $sc = Tcl::Tk::MT::Gfx::create_scene($W, $H);
        $sc->set_clear_color(Tcl::Tk::MT::Gfx::rgba(20, 30, 40, 255), 1);
        my $r1 = $sc->create_item('rectangle', [10, 10, 50, 40]);
        $sc->set_fill($r1, Tcl::Tk::MT::Gfx::rgba(200, 50, 30, 255));
        $sc->set_flags($r1, 0);
        my $im = $sc->create_item('image', [70, 15]);
        $sc->set_image($im, $tid, 16, 16);
        return $sc;
    };

    my $sc_sw = $make_t1->($t_sw);
    my $sc_vk = $make_t1->($t_vk);
    is($sc_sw->render($s_sw), 0, 'Tier 1 software render succeeded');
    is($sc_vk->render($s_vk), 0, 'Tier 1 vulkan render succeeded');

    my ($max_d, $pct) = compare_rgba($s_sw->readback_rgba(), $s_vk->readback_rgba(), 0);
    is($max_d, 0, "Tier 1 Vulkan vs Software exact parity (match=${pct}%)");
    is($s_vk->readback_sha256(), $s_sw->readback_sha256(),
       'Tier 1 SHA-256 match between Vulkan and Software');

    $s_sw->texture_destroy($t_sw);
    $s_vk->texture_destroy($t_vk);
}

# Tier 2: AA SDF shapes + text
{
    my $make_t2 = sub {
        my $sc = Tcl::Tk::MT::Gfx::create_scene($W, $H);
        $sc->set_clear_color(Tcl::Tk::MT::Gfx::rgba(15, 18, 24, 255), 1);
        my $rr = $sc->create_item('rectangle', [10, 10, 60, 50]);
        $sc->set_fill($rr, Tcl::Tk::MT::Gfx::rgba(60, 140, 220, 220));
        $sc->set_corner_radius($rr, 8.0);
        my $ov = $sc->create_item('oval', [65, 15, 115, 55]);
        $sc->set_fill($ov, Tcl::Tk::MT::Gfx::rgba(220, 120, 40, 200));
        my $tx = $sc->create_item('text', [15, 80]);
        $sc->set_text($tx, 'Vulkan!', undef, 12);
        $sc->set_fill($tx, Tcl::Tk::MT::Gfx::rgba(255, 255, 255, 255));
        return $sc;
    };

    my $sc_sw = $make_t2->();
    my $sc_vk = $make_t2->();
    is($sc_sw->render($s_sw), 0, 'Tier 2 software render succeeded');
    is($sc_vk->render($s_vk), 0, 'Tier 2 vulkan render succeeded');

    my ($max_d, $pct) = compare_rgba($s_sw->readback_rgba(), $s_vk->readback_rgba(), 2);
    cmp_ok($max_d, '<=', 2, "Tier 2 Vulkan max channel delta <= 2 (got $max_d)");
    cmp_ok($pct,   '>=', 99.9, sprintf('Tier 2 Vulkan match >= 99.9%% (got %.3f%%)', $pct));
}

done_testing();
