#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

BEGIN {
    use_ok('Tcl::Tk::MT');
    use_ok('Tcl::Tk::MT::Gfx');
    use_ok('Tcl::Tk::MT::Surface');
}

# 1. Null-handle and invalid-argument checks (always run, even without display)
{
    my $null_info = Tcl::Tk::MT::Gfx::surface_native_info(0);
    is(ref($null_info), 'HASH', 'surface_native_info(0) returns hashref');
    is($null_info->{platform},    'none', 'null surface platform is none');
    is($null_info->{view_ptr},    0,      'null surface view_ptr is 0');
    is($null_info->{display_ptr}, 0,      'null surface display_ptr is 0');
    is($null_info->{window_id},   0,      'null surface window_id is 0');
    is($null_info->{x},           0,      'null surface x is 0');
    is($null_info->{y},           0,      'null surface y is 0');
    is($null_info->{width},       0,      'null surface width is 0');
    is($null_info->{height},      0,      'null surface height is 0');
    cmp_ok($null_info->{scale},   '>=', 1.0, 'null surface scale >= 1.0');
    is($null_info->{visible},     0,      'null surface visible is 0');
    is($null_info->{surface_ptr}, 0,      'null surface surface_ptr is 0');
    is($null_info->{realized},    0,      'null surface realized is 0');

    is(Tcl::Tk::MT::Gfx::surface_set_ext_geometry_cb(0, 0, 0, 0), 0,
       'surface_set_ext_geometry_cb(0, ...) returns 0');

    eval { Tcl::Tk::MT::Gfx::surface_request_redraw(0) };
    is($@, '', 'surface_request_redraw(0) is a safe no-op');

    eval { Tcl::Tk::MT::Gfx::surface_destroy_raw(0) };
    is($@, '', 'surface_destroy_raw(0) is a safe no-op');

    eval { Tcl::Tk::MT::Gfx::surface_create_raw(0, '.bad', 100, 100) };
    like($@, qr/null interpreter pointer/, 'surface_create_raw(0, ...) croaks cleanly');

    eval { Tcl::Tk::MT::Surface->new(undef, -width => 100, -height => 100) };
    like($@, qr/requires a parent/, 'Surface->new(undef) croaks cleanly');
}

# 2. Live Tk Surface widget tests (skip if no display available)
SKIP: {
    my $mw = eval { MainWindow->new(-title => 'Surface Test') };
    skip "Tk display not available in this environment: $@", 52 unless $mw;

    $mw->withdraw();

    my $surf = $mw->Surface(-width => 640, -height => 480, -bg => '#0a0e14');
    ok($surf, 'Surface widget constructed via $mw->Surface(...)');
    isa_ok($surf, 'Tcl::Tk::MT::Surface', 'Surface object');
    isa_ok($surf, 'Tcl::Tk::MT::Widget',  'Surface inherits from Tcl::Tk::MT::Widget');
    ok(Exists($surf), 'Exists($surf) is true');
    like("$surf", qr/\A\.s\d+\z/, 'stringification overload returns Tk path');
    is($surf->path, "$surf", 'path() matches stringified path');
    is($surf->cget('-bg'),     '#0a0e14', 'cget(-bg) returns configured color');
    is($surf->cget('-width'),  640,       'cget(-width) returns configured width');
    is($surf->cget('-height'), 480,       'cget(-height) returns configured height');

    # Pre-layout native_info still reports requested dimensions cleanly
    my $pre_info = $surf->native_info();
    is($pre_info->{width},  640, 'pre-layout native_info->{width} reports requested 640');
    is($pre_info->{height}, 480, 'pre-layout native_info->{height} reports requested 480');

    # Geometry manager, focus, bind, configure, winfo via Tcl::Tk::MT::Widget
    my $packed = $surf->pack(-fill => 'both', -expand => 1);
    is($packed, $surf, 'pack() returns $surf for chaining');
    eval { $surf->focus() };
    is($@, '', 'focus() executes without error');

    my $bound_fired = 0;
    $surf->bind('<Configure>' => sub { $bound_fired++ });
    ok(length($surf->bind('<Configure>')) > 0, 'bind() registers event handler');

    $surf->configure(-bg => '#112233');
    is($surf->cget('-bg'), '#112233', 'configure() updates Tk frame options');
    is($surf->winfo('class'), 'Frame', 'winfo(class) reports Frame');

    # Raw pointer & native_info contract
    my $ptr = $surf->surface_ptr();
    cmp_ok($ptr, '>', 0, 'surface_ptr() returns non-zero UV');

    $mw->update('idletasks');
    my $info = $surf->native_info();
    is(ref($info), 'HASH', 'native_info() returns hashref');

    my @expected_keys = qw(
        platform view_ptr display_ptr window_id
        x y width height scale visible surface_ptr realized
    );
    for my $k (@expected_keys) {
        ok(exists $info->{$k}, "native_info has key '$k'");
    }

    is($info->{surface_ptr}, $ptr, 'native_info->{surface_ptr} matches surface_ptr()');
    cmp_ok($info->{width},  '>=', 1,   'native_info->{width} >= 1');
    cmp_ok($info->{height}, '>=', 1,   'native_info->{height} >= 1');
    cmp_ok($info->{scale},  '>=', 1.0, 'native_info->{scale} >= 1.0');
    is($info->{realized}, 1, 'native_info->{realized} is 1');

    if ($^O eq 'darwin') {
        is($info->{platform}, 'cocoa', 'macOS platform is cocoa');
        cmp_ok($info->{view_ptr}, '>', 0, 'macOS view_ptr (NSView*) is non-zero');
    }
    elsif ($^O eq 'MSWin32') {
        is($info->{platform}, 'win32', 'Win32 platform is win32');
        cmp_ok($info->{view_ptr}, '>', 0, 'Win32 view_ptr (HWND) is non-zero');
    }
    else {
        is($info->{platform}, 'x11', 'POSIX platform is x11');
        cmp_ok($info->{display_ptr}, '>', 0, 'X11 display_ptr is non-zero');
    }

    # Callback registration & redraw coalescing
    is(Tcl::Tk::MT::Gfx::surface_set_ext_geometry_cb($ptr, 0, 0, 0), 1,
       'surface_set_ext_geometry_cb with valid surface_ptr returns 1');
    is($surf->set_ext_geometry_cb(0, 0, 0), 1,
       '$surf->set_ext_geometry_cb(0, 0, 0) returns 1');
    is($surf->clear_ext_geometry_cb(), 1,
       '$surf->clear_ext_geometry_cb() returns 1');
    eval { $surf->request_redraw() };
    is($@, '', '$surf->request_redraw() succeeds');

    # Nested surface inside a child Frame + resize via configure
    my $holder = $mw->Frame(-width => 300, -height => 200)->pack();
    my $nested = $holder->Surface(-width => 200, -height => 120)->place(-x => 24, -y => 16);
    ok($nested && $nested->surface_ptr() > 0, 'nested Surface created inside Frame');
    $mw->update('idletasks');
    $nested->configure(-width => 240, -height => 140);
    $mw->update('idletasks');
    my $ninfo = $nested->native_info();
    is($ninfo->{width},  240, 'nested Surface width updated after configure');
    is($ninfo->{height}, 140, 'nested Surface height updated after configure');

    # Destroy lifecycle
    $nested->destroy();
    is($nested->surface_ptr(), 0, 'surface_ptr() is 0 after destroy()');
    ok(!Exists($nested), 'Exists($nested) is false after destroy()');
    my $dead_info = $nested->native_info();
    is($dead_info->{platform}, 'none', 'destroyed Surface native_info platform is none');
    is($dead_info->{realized}, 0,      'destroyed Surface native_info realized is 0');
    eval { $nested->destroy() };
    is($@, '', 'second destroy() is a safe no-op');

    # Direct low-level surface_create_raw / surface_destroy_raw round-trip
    my $raw_ptr = Tcl::Tk::MT::Gfx::surface_create_raw(
        $mw->interp->raw_interp_ptr(), '.raw_surf_test', 160, 90
    );
    cmp_ok($raw_ptr, '>', 0, 'surface_create_raw returned non-zero handle');
    $mw->interp->icall('pack', '.raw_surf_test');
    $mw->update('idletasks');
    my $rinfo = Tcl::Tk::MT::Gfx::surface_native_info($raw_ptr);
    is($rinfo->{width},  160, 'raw surface width matches after layout');
    is($rinfo->{height}, 90,  'raw surface height matches after layout');
    Tcl::Tk::MT::Gfx::surface_request_redraw($raw_ptr);
    Tcl::Tk::MT::Gfx::surface_destroy_raw($raw_ptr);
    $mw->interp->icall('destroy', '.raw_surf_test');

    $surf->destroy();
    $mw->destroy();
}

done_testing();
