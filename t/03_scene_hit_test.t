#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

BEGIN {
    use_ok('Tcl::Tk::MT::Gfx');
}

# 1. Scene creation & item CRUD
my $scene = Tcl::Tk::MT::Gfx::create_scene(800, 600);
ok(defined $scene, 'create_scene returns scene object');

my $r1 = $scene->create_item('rectangle', [10, 10, 110, 110]);
my $r2 = $scene->create_item('rectangle', [50, 50, 150, 150]);
my $o1 = $scene->create_item('oval',      [200, 20, 300, 120]);
my $l1 = $scene->create_item('line',      [10, 200, 100, 200, 100, 290]);
my $a1 = $scene->create_item('arc',       [320, 20, 420, 120]);
# Concave L-shaped polygon for ear-clipping test
my $p1 = $scene->create_item('polygon',   [450, 20, 550, 20, 550, 60, 490, 60, 490, 120, 450, 120]);
my $t1 = $scene->create_item('text',      [50, 350]);

is($r1, 1, 'first item id is 1');
is($r2, 2, 'second item id is 2');

$scene->set_fill($r1, Tcl::Tk::MT::Gfx::rgba(255, 0, 0, 255));
$scene->set_fill($r2, Tcl::Tk::MT::Gfx::rgba(0, 255, 0, 255));
$scene->set_fill($o1, Tcl::Tk::MT::Gfx::rgba(0, 0, 255, 255));
$scene->set_fill($l1, Tcl::Tk::MT::Gfx::rgba(255, 255, 0, 255));
$scene->set_width($l1, 4.0);
$scene->set_line_style($l1, 'round', 'miter', [10, 5], 0.0);
$scene->set_fill($a1, Tcl::Tk::MT::Gfx::rgba(255, 128, 0, 255));
$scene->set_arc_angles($a1, 0, 270, 'pieslice');
$scene->set_fill($p1, Tcl::Tk::MT::Gfx::rgba(128, 0, 255, 255));
$scene->set_outline($p1, Tcl::Tk::MT::Gfx::rgba(0, 0, 0, 255));
$scene->set_width($p1, 2.0);
$scene->set_text($t1, "Hello Tcl::Tk::MT!", undef, 16.0);
$scene->set_anchor($t1, 'nw');

# 2. Tags (bitset lookup)
ok($scene->add_tag($r1, 'box'), 'add_tag box to r1');
ok($scene->add_tag($r2, 'box'), 'add_tag box to r2');
ok($scene->add_tag($r1, 'red'), 'add_tag red to r1');
ok($scene->has_tag($r1, 'box'), 'r1 has tag box');
ok(!$scene->has_tag($o1, 'box'), 'o1 does not have tag box');

my $boxes = $scene->find_withtag('box');
is_deeply($boxes, [$r1, $r2], 'find_withtag(box) returns [r1, r2] in z-order');

my $r1_tags = $scene->get_tags($r1);
is_deeply([sort @$r1_tags], ['box', 'red'], 'get_tags returns all tags on item');

ok($scene->remove_tag($r1, 'red'), 'remove_tag red');
ok(!$scene->has_tag($r1, 'red'), 'r1 no longer has tag red');

# 3. Spatial index: overlapping & enclosed
my $ov = $scene->find_overlapping(60, 60, 80, 80);
is_deeply($ov, [$r1, $r2], 'find_overlapping(60,60,80,80) hits both r1 and r2 in z-order');

my $enc = $scene->find_enclosed(0, 0, 120, 120);
is_deeply($enc, [$r1], 'find_enclosed(0,0,120,120) encloses only r1');

# 4. Z-order & find_closest tie-breaking
is($scene->find_closest(80, 80, 0.0), $r2, 'topmost item r2 wins find_closest in overlap');
ok($scene->raise($r1), 'raise r1 to top');
is($scene->find_closest(80, 80, 0.0), $r1, 'after raise(r1), r1 wins find_closest in overlap');
ok($scene->lower($r1), 'lower r1 to bottom');
is($scene->find_closest(80, 80, 0.0), $r2, 'after lower(r1), r2 wins find_closest again');

# Concave polygon hit test: inside L arm vs inside notch
is($scene->find_closest(470, 100, 0.0), $p1, 'point inside concave polygon hits p1');
is($scene->find_closest(100, 245, 2.0), $l1, 'point on vertical polyline segment hits l1');

# 5. BBox, move, scale, update_coords_packed
my $bb_box = $scene->bbox('box');
ok(defined $bb_box && @$bb_box == 4, 'bbox(box) returns 4-element arrayref');
ok($bb_box->[0] <= 10 && $bb_box->[2] >= 150, 'bbox(box) spans r1 and r2');

is($scene->move('box', 10, 20), 2, 'move(box, 10, 20) moves 2 items');
my $r1_coords = $scene->get_coords($r1);
is_deeply($r1_coords, [20, 30, 120, 130], 'r1 coords updated after move');

ok($scene->update_coords_packed($r1, [10, 10, 110, 110]), 'update_coords_packed succeeds');
is_deeply($scene->get_coords($r1), [10, 10, 110, 110], 'r1 coords restored');

# 6. Batching & zero re-tessellation on pan/zoom
$scene->batch_begin();
is($scene->batch_depth(), 1, 'batch_depth is 1');
$scene->batch_begin();
is($scene->batch_depth(), 2, 'nested batch_depth is 2');
$scene->batch_end();
$scene->batch_end();
is($scene->batch_depth(), 0, 'batch_depth back to 0');

my $dl1 = $scene->tessellate();
ok($dl1->{vertex_count} > 0,   'tessellate emitted vertices (line/polygon/text)');
ok($dl1->{instance_count} >= 4, 'tessellate emitted SDF instances (rects/oval/arc)');
ok($dl1->{cmd_count} > 0,      'tessellate emitted draw commands');

my $st1 = $scene->stats();
is($st1->{tessellate_count}, 1, 'tessellate_count is 1 after first tessellate');

# Pan & zoom must NOT re-tessellate
$scene->pan(40.0, -25.0);
$scene->zoom(1.5, 400.0, 300.0);
my $dl2 = $scene->tessellate();
my $st2 = $scene->stats();
is($st2->{tessellate_count}, 1, 'ZERO re-tessellation after pan/zoom');
ok($st2->{view_only_updates} >= 1, 'view_only_updates incremented');

my $vm = $scene->get_view_matrix();
is(scalar(@$vm), 9, 'get_view_matrix returns 9 floats');
ok(abs($vm->[0] - 1.5) < 1e-4, 'view_matrix scale_x == 1.5');

# 7. Bulk lines batch & 10,000 instanced shapes
my @line_xy;
for my $i (0 .. 99) {
    push @line_xy, $i * 4.0, 400.0, $i * 4.0 + 3.0, 420.0;
}
my $nlines = $scene->create_lines_batch(\@line_xy, Tcl::Tk::MT::Gfx::rgba(0, 128, 255, 255), 1.5);
is($nlines, 100, 'create_lines_batch created 100 line segments');

my @inst_data;
my $cyan = Tcl::Tk::MT::Gfx::rgba(0, 200, 220, 200);
for my $i (0 .. 9999) {
    push @inst_data, ($i % 100) * 6.0, int($i / 100) * 6.0, $cyan, 4.0;
}
my $inst_id = $scene->create_instances(\@inst_data, 2, 1, 4);
ok($inst_id > 0, 'create_instances created 10,000-shape batch');

my $dl3 = $scene->tessellate();
ok($dl3->{instance_count} >= 10000, 'tessellate emitted >= 10,000 instances');

# 8. Delete & clear
ok($scene->delete_item($inst_id), 'delete_item removes instance batch');
is($scene->delete_by_tag('box'), 2, 'delete_by_tag(box) deletes 2 items');

# 9. Render through software backend + put_rgba_packed + deterministic readback
my $surf = Tcl::Tk::MT::Gfx::create_surface(128, 128, 'software', 1.0, 1);
ok(defined $surf, 'created headless software surface');
is($surf->backend_name(), 'software', 'surface backend_name is software');

my @rgba = ((255, 0, 128, 255) x (16 * 16));
my $tex = $surf->put_rgba_packed(0, 16, 16, \@rgba);
ok($tex > 0, 'put_rgba_packed created RGBA8 texture');

my $img_id = $scene->create_item('image', [64, 64]);
ok($scene->set_image($img_id, $tex, 16, 16), 'set_image attached texture to image item');

$scene->set_pan_zoom(0, 0, 1, 1);
is($scene->render($surf), 0, 'scene->render(software_surface) succeeded');
my $hash1 = $surf->readback_sha256();
is(length($hash1), 64, 'readback_sha256 returned 64-char hex digest');

is($scene->render($surf), 0, 'second scene->render succeeded');
my $hash2 = $surf->readback_sha256();
is($hash1, $hash2, 'software scene render readback is bit-exact deterministic');

done_testing();
