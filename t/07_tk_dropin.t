#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Config;

use Tcl::Tk::MT;
use Tcl::Tk::MT::Gfx;
use Tcl::Tk::MT::Canvas;
use Tcl::Tk::MT::Photo;

# 1. Gfx registry & color parsing
{
    Tcl::Tk::MT::Gfx::init();
    my $active = Tcl::Tk::MT::Gfx::active_backend();
    ok(defined $active && length $active, "active graphics backend: $active");

    my $list = Tcl::Tk::MT::Gfx::list_backends();
    ok(ref($list) eq 'ARRAY' && @$list >= 1, 'list_backends returns registered backends');

    is(Tcl::Tk::MT::Gfx::parse_color('#ff0000'), Tcl::Tk::MT::Gfx::rgba(255, 0, 0, 255), 'parse_color #rrggbb');
    is(Tcl::Tk::MT::Gfx::parse_color('#0f0'),    Tcl::Tk::MT::Gfx::rgba(0, 255, 0, 255), 'parse_color #rgb');
    is(Tcl::Tk::MT::Gfx::parse_color('blue'),    Tcl::Tk::MT::Gfx::rgba(0, 0, 255, 255), 'parse_color named blue');
    is(Tcl::Tk::MT::Gfx::parse_color(''),        0, 'parse_color empty -> transparent');
}

# 2. Headless Canvas & Photo tests (always run even without X11 display)
{
    my $hc = Tcl::Tk::MT::Canvas->new(undef, -width => 128, -height => 128, -bg => '#102030', -headless => 1);
    ok($hc->isa('Tcl::Tk::MT::Canvas'), 'headless Canvas constructed');
    ok($hc->is_accelerated, 'headless Canvas is accelerated');

    my $r1 = $hc->createRectangle(10, 10, 60, 60, -fill => '#ff0000', -outline => '#ffffff', -width => 2, -tags => ['box', 'ui']);
    my $l1 = $hc->createLine(0, 0, 120, 120, -fill => '#00ff00', -width => 3, -capstyle => 'round', -joinstyle => 'round');
    my $o1 = $hc->createOval(70, 10, 120, 60, -fill => '#0000ff', -tags => 'ball');
    my $a1 = $hc->createArc(10, 70, 60, 120, -start => 0, -extent => 180, -style => 'pieslice', -fill => 'yellow');
    my $p1 = $hc->createPolygon(70, 70, 120, 70, 95, 120, -fill => 'cyan');
    my $t1 = $hc->createText(64, 64, -text => 'Hi', -fill => 'white', -font => 'Helvetica 14');

    ok($r1 && $l1 && $o1 && $a1 && $p1 && $t1, 'all standard Canvas items created');
    is($hc->itemcget($r1, '-fill'), '#ff0000', 'itemcget returns fill');
    $hc->itemconfigure($r1, -fill => '#ee1122');
    is($hc->itemcget($r1, '-fill'), '#ee1122', 'itemconfigure updates fill');

    my @c = $hc->coords($r1);
    is_deeply(\@c, [10, 10, 60, 60], 'coords getter');
    $hc->coords($r1, 12, 12, 62, 62);
    is_deeply([$hc->coords($r1)], [12, 12, 62, 62], 'coords setter');

    $hc->move('box', 5, -2);
    is_deeply([$hc->coords($r1)], [17, 10, 67, 60], 'move by tag');

    my @tags = sort $hc->gettags($r1);
    is_deeply(\@tags, ['box', 'ui'], 'gettags');
    $hc->addtag('extra', 'withtag', $r1);
    ok((grep { $_ eq 'extra' } $hc->gettags($r1)), 'addtag');
    $hc->dtag($r1, 'extra');
    ok(!(grep { $_ eq 'extra' } $hc->gettags($r1)), 'dtag');

    my @over = $hc->find('overlapping', 20, 20, 30, 30);
    ok((grep { $_ == $r1 } @over), 'find overlapping hits rectangle');
    my @enc = $hc->find('enclosed', 10, 5, 70, 65);
    ok((grep { $_ == $r1 } @enc), 'find enclosed hits rectangle');
    my @wt = $hc->find('withtag', 'ball');
    is_deeply(\@wt, [$o1], 'find withtag');

    my @bb = $hc->bbox($r1);
    is(scalar(@bb), 4, 'bbox returns 4 coordinates');

    $hc->raise($r1);
    $hc->lower($r1);

    # Batch and packed primitives
    my $lines = [ 0, 0, 10, 10,  20, 20, 30, 30,  40, 40, 50, 50 ];
    my $nlines = $hc->createLinesBatch($lines, { -fill => '#aabbcc', -width => 1.5 });
    is($nlines, 3, 'createLinesBatch created 3 lines');

    my $inst_data = [
        20, 20, Tcl::Tk::MT::Gfx::rgba(255, 0, 0, 255), 8,
        40, 40, Tcl::Tk::MT::Gfx::rgba(0, 255, 0, 255), 10,
    ];
    my $inst_id = $hc->createInstances($inst_data, { -shape => 'circle', -aa => 1 });
    ok($inst_id > 0, 'createInstances returned item id');

    my $batch_res = $hc->submit_batch([
        [ createRectangle => 2, 2, 8, 8, -fill => 'white' ],
        [ createOval      => 90, 90, 110, 110, -fill => 'orange' ],
    ]);
    is(scalar(@$batch_res), 2, 'submit_batch executed 2 ops');

    # Photo zero-copy upload & createImage
    my $photo = Tcl::Tk::MT::Photo->new(-width => 8, -height => 8);
    my $rgba  = pack('C*', (255, 128, 0, 255) x 64);
    $photo->put_rgba_packed($rgba, 8, 8);
    my $img_id = $hc->createImage(32, 32, -image => $photo);
    ok($img_id > 0, 'createImage with Photo');

    # Render, view-only pan/zoom, and PostScript export
    $hc->render();
    my $st0 = $hc->stats();
    my $tess0 = $st0->{tessellate_count};
    $hc->pan(10, 5);
    $hc->zoom(1.5, 64, 64);
    $hc->xview('moveto', 0.1);
    $hc->yview('scroll', 1, 'units');
    $hc->render();
    my $st1 = $hc->stats();
    is($st1->{tessellate_count}, $tess0, 'pan/zoom/xview/yview performed zero re-tessellation');
    ok($st1->{view_only_updates} > $st0->{view_only_updates}, 'view_only_updates incremented');

    my $ps = $hc->postscript();
    like($ps, qr/\A%!PS-Adobe-3\.0 EPSF-3\.0/, 'postscript header valid');
    like($ps, qr/colorimage/, 'postscript contains colorimage');

    $hc->delete($l1);
    ok(!(grep { $_ == $l1 } $hc->find('all')), 'delete removed item');
}

# 3. Live Tk widget & drop-in tests (skip only if headless Linux without DISPLAY)
SKIP: {
    my $mw = eval { MainWindow->new(-title => 'Tcl::Tk::MT Test') };
    skip "No Tk display available: $@", 16 unless $mw;

    $mw->withdraw();
    ok(Exists($mw), 'MainWindow exists');
    is($mw->title(), 'Tcl::Tk::MT Test', 'wm title round-trip');

    my $f  = $mw->Frame()->pack(-fill => 'both', -expand => 1);
    my $b  = $f->Button(-text => 'Click', -command => sub {})->pack(-side => 'left');
    my $l  = $f->Label(-text => 'Hello')->pack(-side => 'left');
    my $e  = $f->Entry()->pack(-side => 'left');
    my $tb = $f->ttkButton(-text => 'Ttk')->pack(-side => 'left');
    my $nb = $f->Notebook()->pack();
    my $tv = $f->Treeview()->pack();
    my $sb = $f->Scrollbar()->pack();
    my $tx = $f->Text(-width => 20, -height => 4)->pack();
    my $mn = $mw->Menu();
    my $tl = $mw->Toplevel();
    $tl->withdraw();

    ok(Exists($b) && Exists($l) && Exists($e) && Exists($tb), 'classic and ttk widgets created');
    ok(Exists($nb) && Exists($tv) && Exists($sb) && Exists($tx) && Exists($mn) && Exists($tl), 'Notebook/Treeview/Scrollbar/Text/Menu/Toplevel created');
    is($b->cget('-text'), 'Click', 'Button cget -text');
    $b->configure(-text => 'Updated');
    is($b->cget('-text'), 'Updated', 'Button configure -text');

    # bind & after / afterCancel
    my $fired = 0;
    my $aid = $mw->after(5, sub { $fired++ });
    ok(defined $aid && length $aid, 'after returns timer id');
    my $cid = $mw->after(5000, sub { $fired += 100 });
    $mw->afterCancel($cid);
    $mw->bind('<Key-a>', [ sub {}, Ev('x', 'y') ]);
    pass('bind with Ev accepted');

    # Transparent accelerated Canvas by default
    my $c = $mw->Canvas(-width => 160, -height => 120, -headless => 1)->pack();
    ok($c->isa('Tcl::Tk::MT::Canvas') && $c->is_accelerated, '$mw->Canvas returns accelerated Tcl::Tk::MT::Canvas by default');

    # createWindow child placement
    my $child_btn = $mw->Button(-text => 'Embedded');
    my $wid = $c->createWindow(20, 20, -window => $child_btn, -width => 60, -height => 24);
    ok($wid > 0, 'createWindow embeds Tk child widget');

    # Explicit -accel => 0 fallback to native Tk canvas
    my $nc1 = $mw->Canvas(-width => 100, -height => 80, -accel => 0);
    ok($nc1->isa('Tcl::Tk::MT::NativeCanvas') && !$nc1->is_accelerated, '-accel => 0 falls back to NativeCanvas');
    my $nid = $nc1->createRectangle(5, 5, 50, 50, -fill => 'red');
    ok($nid, 'NativeCanvas createRectangle works');

    # TCL_TK_MT_ACCEL=off fallback
    {
        local $ENV{TCL_TK_MT_ACCEL} = 'off';
        my $nc2 = $mw->Canvas(-width => 100, -height => 80);
        ok($nc2->isa('Tcl::Tk::MT::NativeCanvas') && !$nc2->is_accelerated, 'TCL_TK_MT_ACCEL=off falls back to NativeCanvas');
    }

    # Photo on-demand Tk mirror
    my $p = $mw->Photo(-width => 4, -height => 4);
    $p->put_rgba_packed(pack('C*', (0, 255, 128, 255) x 16), 4, 4);
    my $tk_img = $p->tk_photo();
    ok(defined $tk_img && length $tk_img, 'Photo::tk_photo creates on-demand Tk photo mirror');
    is($mw->interp->icall_scalar('image', 'width', $tk_img), 4, 'Tk photo mirror width matches');

    $tl->destroy();
    $mw->destroy();
}

# 4. `-MTcl::Tk::MT=:dropin` shim verification in a fresh subprocess
{
    my @inc_args = map { "-I$_" } grep { !ref($_) && -d $_ } @INC;
    my $code = <<'END_CODE';
use strict;
use warnings;
use Tcl::Tk;
die "INC missing" unless $INC{'Tcl/Tk.pm'};
die "Shim not installed" unless Tcl::Tk::MT::Shim::is_installed();
my $c = Tcl::Tk::MT::Canvas->new(undef, -width => 64, -height => 64, -headless => 1);
die "Not accelerated" unless $c->is_accelerated;
print "DROPIN_OK:" . $c->backend_name . "\n";
END_CODE
    open my $fh, '-|', $^X, @inc_args, '-MTcl::Tk::MT=:dropin', '-e', $code
        or die "spawn failed: $!";
    my $out = do { local $/; <$fh> };
    close $fh;
    is($?, 0, '-MTcl::Tk::MT=:dropin subprocess exited cleanly');
    like($out, qr/DROPIN_OK:\w+/, '-MTcl::Tk::MT=:dropin transparently accelerates unmodified `use Tcl::Tk;`');
}

done_testing();
