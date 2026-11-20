#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

BEGIN {
    use_ok('Tcl::Tk::MT::Gfx');
}

is(Tcl::Tk::MT::Gfx::init(), 0, 'tkmt_gfx_init returns 0');

my $list = Tcl::Tk::MT::Gfx::list_backends();
ok(ref($list) eq 'ARRAY' && @$list >= 1, 'list_backends returns non-empty arrayref');

my %by_name = map { $_->{name} => $_ } @$list;
ok(exists $by_name{software}, 'software backend is registered');
ok($by_name{software}{available}, 'software backend is always available');
is(Tcl::Tk::MT::Gfx::backend_available('software'), 1, 'backend_available(software) == 1');
is(Tcl::Tk::MT::Gfx::backend_available('no_such_backend'), 0, 'unknown backend unavailable');

# Explicit software selection
Tcl::Tk::MT::Gfx::reset_for_test('software');
is(Tcl::Tk::MT::Gfx::active_backend(), 'software', 'reset_for_test(software) activates software');
is(Tcl::Tk::MT::Gfx::is_enabled(), 1, 'is_enabled() == 1 in software mode');

my $info = Tcl::Tk::MT::Gfx::active_backend_info();
ok(ref($info) eq 'HASH', 'active_backend_info returns hashref');
is($info->{name}, 'software', 'active_backend_info->{name} is software');
ok($info->{caps} > 0, 'software backend reports capability flags');

# Off mode
Tcl::Tk::MT::Gfx::reset_for_test('off');
is(Tcl::Tk::MT::Gfx::is_enabled(), 0, 'is_enabled() == 0 when mode is off');

# Unknown backend falls back to software twin
Tcl::Tk::MT::Gfx::reset_for_test('nonexistent_gpu');
is(Tcl::Tk::MT::Gfx::active_backend(), 'software', 'unknown backend falls back to software');

# PERL_FORCE_SCALAR=1 forces software twin even in auto mode
{
    local $ENV{PERL_FORCE_SCALAR} = '1';
    Tcl::Tk::MT::Gfx::reset_for_test('auto');
    is(Tcl::Tk::MT::Gfx::active_backend(), 'software',
       'PERL_FORCE_SCALAR=1 forces software backend in auto mode');
}

# Auto mode without PERL_FORCE_SCALAR
{
    local $ENV{PERL_FORCE_SCALAR} = '0';
    Tcl::Tk::MT::Gfx::reset_for_test('auto');
    my $active = Tcl::Tk::MT::Gfx::active_backend();
    ok(defined $active && length($active) > 0, "auto mode selected backend: $active");
    if ($^O eq 'darwin' && Tcl::Tk::MT::Gfx::backend_available('metal')) {
        is($active, 'metal', 'auto mode picks metal on macOS when available');
    }
}

# Telemetry stats check
Tcl::Tk::MT::Gfx::reset_for_test('software');
Tcl::Tk::MT::Gfx::reset_stats();
my $s0 = Tcl::Tk::MT::Gfx::stats();
is($s0->{frames_rendered}, 0, 'stats frames_rendered starts at 0 after reset');
is($s0->{readback_calls},  0, 'stats readback_calls starts at 0 after reset');

my $surf  = Tcl::Tk::MT::Gfx::create_surface(32, 32, 'software', 1.0, 1);
my $scene = Tcl::Tk::MT::Gfx::create_scene(32, 32);
$scene->set_clear_color(Tcl::Tk::MT::Gfx::rgba(10, 20, 30, 255), 1);
my $r = $scene->create_item('rectangle', [4, 4, 28, 28]);
$scene->set_fill($r, Tcl::Tk::MT::Gfx::rgba(200, 100, 50, 255));
is($scene->render($surf), 0, 'render on software surface succeeded');
my $px = $surf->readback_rgba();
is(length($px), 32 * 32 * 4, 'readback_rgba returned 32*32*4 bytes');

my $s1 = Tcl::Tk::MT::Gfx::stats();
cmp_ok($s1->{frames_rendered}, '>=', 1, 'frames_rendered incremented');
cmp_ok($s1->{readback_calls},  '>=', 1, 'readback_calls incremented');
is($s1->{last_backend_name}, 'software', 'last_backend_name is software');

done_testing();
