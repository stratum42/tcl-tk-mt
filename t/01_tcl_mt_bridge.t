use strict;
use warnings;
use Test::More;

use Tcl::MT qw(DONT_WAIT ALL_EVENTS);

# 1. Version & build metadata
my $ver = Tcl::MT::tcl_version();
ok(defined $ver && $ver =~ /^\d+\.\d+/, "tcl_version() returns valid version ($ver)");
my $is_mt = Tcl::MT::is_perl5_mt();
ok(defined $is_mt && ($is_mt == 0 || $is_mt == 1), "is_perl5_mt() = $is_mt");
my $has_packed = Tcl::MT::have_packed_av();
ok(defined $has_packed && ($has_packed == 0 || $has_packed == 1), "have_packed_av() = $has_packed");

# 2. Interpreter creation & basic Eval
my $interp = Tcl::MT->new();
ok($interp, "Tcl::MT->new() succeeded");
ok(!$interp->has_tk(), "has_tk() is false before Init");
ok($interp->raw_interp_ptr() > 0, "raw_interp_ptr() is non-zero");

is($interp->Eval('expr {6 * 7}'), '42', 'Eval arithmetic');
is($interp->Eval('string toupper "hello"'), 'HELLO', 'Eval string command');

eval { $interp->Eval('error "intentional_boom"') };
like($@, qr/intentional_boom/, 'Eval propagates Tcl errors to $@');

# 3. Direct icall / call fast path & interned Tcl_Obj* cache
is($interp->icall('expr', '10 + 32'), '42', 'icall expr');
is($interp->call('string', 'length', 'abcdef'), '6', 'call alias works');
is($interp->icall('set', 'x', 123), '123', 'icall set integer');
is($interp->icall('set', 'pi', 3.5), '3.5', 'icall set float');

# List conversion (Perl ARRAY -> Tcl list, Tcl list -> Perl list)
my @elems = $interp->icall('list', 'alpha', 'beta gamma', [1, 2, 3]);
is(scalar(@elems), 3, 'icall in list context returns 3 elements');
is($elems[0], 'alpha', 'list elem 0');
is($elems[1], 'beta gamma', 'list elem 1 with space preserved');
is($elems[2], '1 2 3', 'nested arrayref converted to Tcl list');

my $scalar_list = $interp->icall_scalar('list', 'a', 'b', 'c');
is($scalar_list, 'a b c', 'icall_scalar returns stringified list');

my @forced_list = $interp->icall_list('list', 'x', 'y');
is_deeply(\@forced_list, ['x', 'y'], 'icall_list returns list');

# Intern cache should have cached commands and -option flags
$interp->icall('string', 'equal', '-nocase', 'Foo', 'foo');
cmp_ok($interp->intern_count(), '>=', 3, 'intern_count() cached commands and -options');

# 4. Variables (GetVar / SetVar / GetVar2 / SetVar2 / UnsetVar)
$interp->SetVar('greeting', 'hello world');
is($interp->GetVar('greeting'), 'hello world', 'SetVar/GetVar round-trip');
$interp->SetVar2('arr', 'key1', 'val1');
is($interp->GetVar2('arr', 'key1'), 'val1', 'SetVar2/GetVar2 round-trip');
ok($interp->UnsetVar('greeting'), 'UnsetVar succeeds');
ok(!defined $interp->GetVar('greeting'), 'GetVar returns undef after UnsetVar');

# 5. Perl callbacks from Tcl (CreateCommand, inline CodeRef, DeleteCommand)
my @seen_args;
$interp->CreateCommand('perl_add', sub {
    @seen_args = @_;
    return ($_[0] // 0) + ($_[1] // 0);
});
is($interp->Eval('perl_add 19 23'), '42', 'CreateCommand invokes Perl closure and returns result');
is_deeply(\@seen_args, ['19', '23'], 'CreateCommand passed Tcl args to Perl');

$interp->CreateCommand('perl_die', sub { die "perl_callback_died\n" });
eval { $interp->Eval('perl_die') };
like($@, qr/perl_callback_died/, 'Perl die in callback propagates as Tcl error');

ok($interp->DeleteCommand('perl_add'), 'DeleteCommand removes command');
eval { $interp->Eval('perl_add 1 2') };
like($@, qr/invalid command name/, 'Deleted command is no longer callable');

# Inline CodeRef passed to icall
my $cb_ran = 0;
my $cb_name = $interp->icall('set', 'my_cb', sub { $cb_ran += ($_[0] // 1); return "ok:$cb_ran" });
like($cb_name, qr/^::perl_mt_cb_\d+$/, 'Inline CodeRef registered as Tcl callback command');
is($interp->Eval('$my_cb 5'), 'ok:5', 'Inline CodeRef callable from Tcl');
is($cb_ran, 5, 'Inline CodeRef mutated Perl state');

# 6. Owning UI-thread guard
ok($interp->is_owner_thread(), 'is_owner_thread() is true on creator thread');
is($interp->owner_tid(), Tcl::MT::current_tid(), 'owner_tid() matches current_tid()');

# 7. Lock-free MPSC marshal queue
ok($interp->marshal_eval_async('set mpsc_async_val 99'), 'marshal_eval_async queued');
my $drained = $interp->drain_marshal_queue();
cmp_ok($drained, '>=', 1, 'drain_marshal_queue processed queued item');
is($interp->GetVar('mpsc_async_val'), '99', 'marshal_eval_async executed on Tcl interp');

my $sync_res = $interp->marshal_eval_sync('expr {100 + 23}');
is($sync_res, '123', 'marshal_eval_sync returns result on UI thread');
cmp_ok($interp->marshal_count(), '>=', 2, 'marshal_count() incremented');

# DoOneEvent non-blocking sanity check
my $ev_rc = $interp->DoOneEvent(ALL_EVENTS() | DONT_WAIT());
ok(defined $ev_rc, 'DoOneEvent(ALL_EVENTS | DONT_WAIT) returns without blocking');

# 8. Optional Tk init & surface creation (skip if no display available)
SKIP: {
    my $tk_ok = eval { $interp->Init(); 1 };
    skip "Tk display not available in this environment: $@", 4 unless $tk_ok;

    ok($interp->has_tk(), 'has_tk() is true after Init');
    $interp->Eval('wm withdraw .');

    my $surf = $interp->create_surface('.test_surf', 160, 120);
    ok($surf && $surf->ptr() > 0, 'create_surface returned valid Tcl::MT::Surface');
    is($surf->path(), '.test_surf', 'surface path matches');

    # Test Tk photo RGBA blit helper
    $interp->Eval('image create photo test_photo -width 4 -height 4');
    my $rgba = pack('C*', (255, 0, 128, 255) x 16);
    ok($interp->blit_rgba_photo('test_photo', $rgba, 4, 4), 'blit_rgba_photo succeeded');

    $surf->destroy();
}

$interp->destroy();
done_testing();
