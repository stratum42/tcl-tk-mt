#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

BEGIN {
    use_ok('Tcl::Tk::MT::Gfx');
}

Tcl::Tk::MT::Gfx::reset_for_test('software');

my ($W, $H) = (128, 128);
my $surf = Tcl::Tk::MT::Gfx::create_surface($W, $H, 'software', 1.0, 1);
ok(defined $surf, 'created headless software surface');
is($surf->backend_name(), 'software', 'surface backend_name is software');
is($surf->width(),  $W, 'surface width matches');
is($surf->height(), $H, 'surface height matches');

sub get_pixel {
    my ($buf, $w, $x, $y) = @_;
    my $off = ($y * $w + $x) * 4;
    return unpack('C4', substr($buf, $off, 4));
}

# 1. Clear color + solid non-AA rectangle
my $scene = Tcl::Tk::MT::Gfx::create_scene($W, $H);
$scene->set_clear_color(Tcl::Tk::MT::Gfx::rgba(12, 34, 56, 255), 1);
my $rect = $scene->create_item('rectangle', [10, 10, 50, 40]);
$scene->set_fill($rect, Tcl::Tk::MT::Gfx::rgba(200, 50, 25, 255));
$scene->set_flags($rect, 0); # non-AA

is($scene->render($surf), 0, 'rendered clear + rect');
my $buf = $surf->readback_rgba();
is(length($buf), $W * $H * 4, 'readback size exact');

is_deeply([get_pixel($buf, $W, 2, 2)],   [12, 34, 56, 255],  'background pixel exact');
is_deeply([get_pixel($buf, $W, 20, 20)], [200, 50, 25, 255], 'rect interior pixel exact');

# 2. Full primitive coverage: rounded rect, oval, arc, polyline, polygon, instances, RGBA8 texture, R8 text
my $rrect = $scene->create_item('rectangle', [60, 10, 115, 45]);
$scene->set_fill($rrect, Tcl::Tk::MT::Gfx::rgba(40, 180, 90, 220));
$scene->set_outline($rrect, Tcl::Tk::MT::Gfx::rgba(255, 255, 255, 255));
$scene->set_width($rrect, 2.0);
$scene->set_corner_radius($rrect, 8.0);

my $oval = $scene->create_item('oval', [10, 50, 55, 95]);
$scene->set_fill($oval, Tcl::Tk::MT::Gfx::rgba(60, 100, 240, 255));

my $arc = $scene->create_item('arc', [65, 50, 115, 95]);
$scene->set_fill($arc, Tcl::Tk::MT::Gfx::rgba(240, 180, 30, 255));
$scene->set_arc_angles($arc, 20, 220, 'pieslice');

my $line = $scene->create_item('line', [8, 105, 50, 115, 90, 102]);
$scene->set_fill($line, Tcl::Tk::MT::Gfx::rgba(255, 80, 200, 255));
$scene->set_width($line, 3.0);
$scene->set_line_style($line, 'round', 'miter', [], 0.0);

my $poly = $scene->create_item('polygon', [95, 100, 122, 104, 116, 124, 98, 120]);
$scene->set_fill($poly, Tcl::Tk::MT::Gfx::rgba(140, 60, 220, 255));

# Instanced circles (stride 4: x, y, rgba, size)
my @inst_data;
for my $i (0 .. 9) {
    push @inst_data, 15 + $i * 10, 122, Tcl::Tk::MT::Gfx::rgba(255, 255, 100, 255), 5;
}
my $inst_id = $scene->create_instances(\@inst_data, 2, 1, 4);
ok($inst_id > 0, 'created instanced circles item');

# Alpha-blended RGBA8 texture (8x8)
my $tex_bytes = '';
for my $y (0 .. 7) {
    for my $x (0 .. 7) {
        $tex_bytes .= pack('C4', $x * 32, $y * 32, 180, 200);
    }
}
my $tex_id = $surf->texture_create_rgba(8, 8, $tex_bytes);
ok($tex_id > 0, 'created RGBA8 texture');
my $img_item = $scene->create_item('image', [52, 10]);
$scene->set_image($img_item, $tex_id, 8, 8);

# R8 glyph atlas text
my $txt_item = $scene->create_item('text', [12, 112]);
$scene->set_text($txt_item, 'TkMT', undef, 12);
$scene->set_fill($txt_item, Tcl::Tk::MT::Gfx::rgba(255, 255, 255, 255));

is($scene->render($surf), 0, 'rendered full primitive scene');
my $sha1 = $surf->readback_sha256();
my $raw1 = $surf->readback_rgba();
is(length($sha1), 64, 'readback_sha256 returns 64-char hex digest');
is($sha1, Tcl::Tk::MT::Gfx::sha256_hex($raw1), 'readback_sha256 matches sha256_hex(readback_rgba)');

# Determinism: second render must match SHA-256 bit-for-bit
is($scene->render($surf), 0, 'second render succeeded');
my $sha2 = $surf->readback_sha256();
is($sha2, $sha1, 'software rasterizer is 100% bit-for-bit deterministic');

# Pan/zoom view transform changes pixels without re-tessellating
my $st_before = $scene->stats();
$scene->set_pan_zoom(10.0, 5.0, 1.25, 1.25);
is($scene->render($surf), 0, 'rendered after pan/zoom');
my $sha3 = $surf->readback_sha256();
isnt($sha3, $sha1, 'pan/zoom changes rendered framebuffer');
my $st_after = $scene->stats();
is($st_after->{tessellate_count}, $st_before->{tessellate_count},
   'pan/zoom caused zero re-tessellations');

# Resize surface
is($surf->resize(64, 48, 1.0), 0, 'resize surface succeeded');
is($surf->width(),  64, 'resized width == 64');
is($surf->height(), 48, 'resized height == 48');
$scene->set_viewport(64, 48);
is($scene->render($surf), 0, 'render after resize succeeded');
is(length($surf->readback_rgba()), 64 * 48 * 4, 'readback matches resized dimensions');

$surf->texture_destroy($tex_id);
done_testing();
