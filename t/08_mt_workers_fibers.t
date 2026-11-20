#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use Tcl::MT;
use Tcl::Tk::MT;
use Tcl::Tk::MT::Gfx;
use Tcl::Tk::MT::Canvas;
use Tcl::Tk::MT::Photo;
use Tcl::Tk::MT::Dispatch;

# 1. Dispatch capability flags
my $is_mt = Tcl::Tk::MT::Gfx::is_perl5_mt();
is(Tcl::Tk::MT::Dispatch::has_mt() ? 1 : 0, $is_mt ? 1 : 0, 'Dispatch::has_mt matches XS is_perl5_mt');

# 2. MPSC Tcl marshal queue & UI callback queue
{
    my $interp = Tcl::MT->new(init_tk => 0);
    ok(Tcl::Tk::MT::Dispatch::is_ui_thread($interp), 'owner thread detected as UI thread');

    $interp->marshal_eval_async('set ::mpsc_test_val 42');
    my $drained = Tcl::Tk::MT::Dispatch::pump_once($interp);
    ok($drained >= 1, 'pump_once drained MPSC marshal queue');
    is($interp->GetVar('::mpsc_test_val'), '42', 'marshaled Tcl command executed');

    my $ui_ran = 0;
    Tcl::Tk::MT::Dispatch::post_ui($interp, sub { $ui_ran += 7 });
    Tcl::Tk::MT::Dispatch::pump_once($interp);
    is($ui_ran, 7, 'post_ui callback executed on pump_once');
}

# 3. Cooperative MT::Fiber pumping (works on perl5-mt with real MT::Fiber and degrades cleanly on stock Perl 5)
{
    my $interp = Tcl::MT->new(init_tk => 0);
    my $canvas = Tcl::Tk::MT::Canvas->new(undef, -width => 128, -height => 128, -headless => 1);
    my @trace;

    my $f1 = Tcl::Tk::MT::Dispatch::schedule_fiber(sub {
        push @trace, 'f1:a';
        $canvas->createRectangle(5, 5, 25, 25, -fill => '#ff0000', -tags => 'fiber1');
        Tcl::Tk::MT::Dispatch::fiber_yield();
        push @trace, 'f1:b';
        return 101;
    }, $interp);

    my $f2 = Tcl::Tk::MT::Dispatch::schedule_fiber(sub {
        push @trace, 'f2:a';
        $canvas->createOval(30, 30, 60, 60, -fill => '#00ff00', -tags => 'fiber2');
        Tcl::Tk::MT::Dispatch::fiber_yield();
        push @trace, 'f2:b';
        return 202;
    }, $interp);

    Tcl::Tk::MT::Dispatch::pump_once($interp);

    is(scalar(@trace), 4, 'both scheduled fibers ran to completion via pump_once');
    if (Tcl::Tk::MT::Dispatch::has_fiber()) {
        # Exact round-robin interleaving on perl5-mt MT::Fiber
        is_deeply(\@trace, [ 'f1:a', 'f2:a', 'f1:b', 'f2:b' ], 'MT::Fiber interleaved cooperatively');
        is(MT::Fiber::join($f1), 101, 'MT::Fiber::join f1 result');
        is(MT::Fiber::join($f2), 202, 'MT::Fiber::join f2 result');
    }
    else {
        pass('stock Perl 5 fiber fallback ran both tasks');
    }

    my @all = $canvas->find('all');
    is(scalar(@all), 2, 'fibers populated Canvas items');
    $canvas->render();
    my $sha = $canvas->readback_sha256();
    like($sha, qr/\A[0-9a-f]{64}\z/, 'Canvas rendered after fiber updates');
}

# 4. Channel frame streaming (MT::Channel on perl5-mt, FallbackChannel on stock Perl 5)
{
    my $interp = Tcl::MT->new(init_tk => 0);
    my $canvas = Tcl::Tk::MT::Canvas->new(undef, -width => 128, -height => 128, -headless => 1);
    my $ch     = Tcl::Tk::MT::Dispatch::create_channel(16);

    my $frames_applied = 0;
    my $sub_id = Tcl::Tk::MT::Dispatch::attach_channel($interp, $ch, sub {
        my ($frame) = @_;
        my ($x0, $y0, $x1, $y1, $color) = split /,/, $frame;
        $canvas->createRectangle($x0, $y0, $x1, $y1, -fill => $color);
        $frames_applied++;
    });

    $ch->send('10,10,40,40,#ff0000');
    $ch->send('50,50,90,90,#0000ff');
    Tcl::Tk::MT::Dispatch::pump_once($interp);

    is($frames_applied, 2, 'attached channel drained 2 frames into Canvas');
    my @ch_items = $canvas->find('all');
    is(scalar(@ch_items), 2, 'Canvas has 2 items from channel stream');
    is(Tcl::Tk::MT::Dispatch::detach_channel($interp, $sub_id), 1, 'detach_channel removed subscription');
}

# 5. Zero-copy SVf_PACKED_AV (AV_PACKED_NV / AV_PACKED_U8) fast path
{
    my $canvas = Tcl::Tk::MT::Canvas->new(undef, -width => 128, -height => 128, -headless => 1);
    my $photo  = Tcl::Tk::MT::Photo->new(-width => 8, -height => 8, -surface => $canvas->surface);

    my ($lines_av, $inst_av, $u8_av);
    if (Tcl::Tk::MT::Dispatch::has_packed_av() && Tcl::Tk::MT::Gfx::have_packed_av()) {
        $lines_av = MT::Array::packed('NV', 0, 0, 100, 100, 10, 90, 90, 10);
        $inst_av  = MT::Array::packed('NV',
            32, 32, Tcl::Tk::MT::Gfx::rgba(255, 0, 0, 255), 12,
            96, 96, Tcl::Tk::MT::Gfx::rgba(0, 255, 0, 255), 12,
        );
        $u8_av = MT::Array::packed('U8', (200, 100, 50, 255) x 64);

        ok(Tcl::Tk::MT::Gfx::av_packed_type($lines_av) > 0, 'lines_av is packed NV');
        ok(Tcl::Tk::MT::Gfx::av_packed_type($u8_av) > 0,    'u8_av is packed U8');
    }
    else {
        $lines_av = [ 0, 0, 100, 100, 10, 90, 90, 10 ];
        $inst_av  = [
            32, 32, Tcl::Tk::MT::Gfx::rgba(255, 0, 0, 255), 12,
            96, 96, Tcl::Tk::MT::Gfx::rgba(0, 255, 0, 255), 12,
        ];
        $u8_av = [ (200, 100, 50, 255) x 64 ];
        pass('stock Perl 5 arrayref fallback for packed primitives');
    }

    my $n = $canvas->createLinesBatch($lines_av, { -fill => '#ffffff', -width => 2 });
    is($n, 2, 'createLinesBatch succeeded with packed NV');

    my $iid = $canvas->createInstances($inst_av, { -shape => 'circle', -aa => 1 });
    ok($iid > 0, 'createInstances succeeded with packed NV');

    my $tex_id = $photo->put_rgba_packed($u8_av, 8, 8);
    ok($tex_id > 0, 'Photo::put_rgba_packed succeeded with packed U8');

    $canvas->createImage(64, 64, -image => $photo);
    $canvas->render();
    like($canvas->readback_sha256(), qr/\A[0-9a-f]{64}\z/, 'Canvas rendered packed lines + instances + photo');
}

# 6. Real perl5-mt MT::Pool worker -> MT::Channel -> UI thread Canvas streaming
sub _tkmt_worker_frame_job {
    my ($spec) = @_;
    my ($idx, $cname) = split /:/, $spec, 2;
    my $wch = MT::Channel->named($cname);
    my $x0 = $idx * 10;
    my $y0 = $idx * 8;
    $wch->send("$x0,$y0," . ($x0 + 20) . "," . ($y0 + 20));
    return $idx;
}

SKIP: {
    skip "MT::Pool/MT::Channel not available on stock Perl 5", 3
        unless Tcl::Tk::MT::Dispatch::has_pool() && Tcl::Tk::MT::Dispatch::has_channel();

    my $chan_name = "tkmt_frame_stream_$$";
    my $ch = MT::Channel->named($chan_name, 32);

    eval { MT::Image::freeze() };
    my $pool = MT::Pool->new(workers => 2);
    my @jobs = map { "$_:$chan_name" } 1 .. 6;
    my @rets = $pool->map(\&_tkmt_worker_frame_job, @jobs);
    $pool->shutdown();

    is(scalar(@rets), 6, 'MT::Pool workers completed 6 frame jobs');

    my $interp = Tcl::MT->new(init_tk => 0);
    my $canvas = Tcl::Tk::MT::Canvas->new(undef, -width => 256, -height => 256, -headless => 1);
    my $received = 0;
    Tcl::Tk::MT::Dispatch::attach_channel($interp, $ch, sub {
        my ($msg) = @_;
        my ($x0, $y0, $x1, $y1) = split /,/, $msg;
        $canvas->createRectangle($x0, $y0, $x1, $y1, -fill => '#3399ff');
        $received++;
    });

    Tcl::Tk::MT::Dispatch::pump_once($interp);
    is($received, 6, 'UI thread drained all 6 worker frames from MT::Channel');
    $canvas->render();
    my @pool_items = $canvas->find('all');
    is(scalar(@pool_items), 6, 'Canvas contains all 6 rectangles streamed from MT::Pool workers');
}

done_testing();
