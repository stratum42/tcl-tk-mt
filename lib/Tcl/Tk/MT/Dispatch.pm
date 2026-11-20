package Tcl::Tk::MT::Dispatch;

use strict;
use warnings;
use Scalar::Util qw(refaddr weaken);

our $VERSION = '0.01';

# Detect perl5-mt capabilities at load time; fall back to in-process queues on stock Perl 5.
our ($HAS_MT, $HAS_FIBER, $HAS_CHANNEL, $HAS_POOL, $HAS_PACKED_AV);

BEGIN {
    $HAS_MT        = eval { require MT; 1 } ? 1 : 0;
    $HAS_FIBER     = (defined(&MT::Fiber::schedule) && defined(&MT::Fiber::run)) ? 1 : 0;
    $HAS_CHANNEL   = ($HAS_MT && eval { require MT::Channel; 1 }) ? 1 : 0;
    $HAS_POOL      = ($HAS_MT && eval { require MT::Pool; 1 })    ? 1 : 0;
    $HAS_PACKED_AV = ($HAS_MT && eval { require MT::Array; 1 })   ? 1 : 0;
}

sub has_mt        { $HAS_MT }
sub has_fiber     { $HAS_FIBER }
sub has_channel   { $HAS_CHANNEL }
sub has_pool      { $HAS_POOL }
sub has_packed_av { $HAS_PACKED_AV }

# Per-interp channel subscriptions and UI-thread callback queues, keyed by refaddr($interp).
my %CHANNELS;       # $interp_key => [ { id => $sub_id, chan => $ch, cb => $cb, max => $n, on_close => $cb }, ... ]
my %UI_QUEUE;       # $interp_key => [ $coderef, ... ]
my %PUMP_HOOKED;    # $interp_key => 1
my $NEXT_SUB_ID = 1;

sub _interp_key {
    my ($interp) = @_;
    return defined($interp) ? refaddr($interp) : 0;
}

sub is_ui_thread {
    my ($class_or_interp, $maybe_interp) = @_;
    my $interp = ref($class_or_interp) ? $class_or_interp : $maybe_interp;
    return 1 unless defined $interp && $interp->can('is_owner_thread');
    return $interp->is_owner_thread ? 1 : 0;
}

# Execute a Tcl script on the UI thread, marshaling via the MPSC queue if called off-thread.
sub marshal_tcl {
    my ($interp, $script, $sync) = @_;
    if ($interp->is_owner_thread) {
        return $interp->Eval($script);
    }
    if ($sync) {
        return $interp->marshal_eval_sync($script);
    }
    $interp->marshal_eval_async($script);
    return;
}

# Execute an icall-style Tcl command on the UI thread, marshaling if called off-thread.
sub marshal_icall {
    my ($interp, $sync, @args) = @_;
    if ($interp->is_owner_thread) {
        return $interp->icall(@args);
    }
    my $script = _tcl_list_escape(@args);
    return $sync
        ? $interp->marshal_eval_sync($script)
        : $interp->marshal_eval_async($script);
}

sub _tcl_list_escape {
    return join(' ', map {
        my $s = defined($_) ? "$_" : '';
        if ($s eq '') {
            '{}';
        }
        elsif ($s =~ /[\s{}\[\]\$\"\\;]/) {
            $s =~ s/\\/\\\\/g;
            $s =~ s/\{/\\\{/g;
            $s =~ s/\}/\\\}/g;
            "{$s}";
        }
        else {
            $s;
        }
    } @_);
}

# Schedule a Perl callback to run on the UI thread on the next pump cycle.
sub post_ui {
    my ($interp, $cb) = @_;
    die "post_ui requires a CODE ref" unless ref($cb) eq 'CODE';
    my $key = _interp_key($interp);
    push @{ $UI_QUEUE{$key} }, $cb;
    return 1;
}

# Schedule a cooperative fiber (MT::Fiber::schedule on perl5-mt, or UI queue fallback on stock Perl).
sub schedule_fiber {
    my ($code, $interp) = @_;
    die "schedule_fiber requires a CODE ref" unless ref($code) eq 'CODE';
    if ($HAS_FIBER) {
        return MT::Fiber::schedule($code);
    }
    # Stock Perl 5 fallback: run on next pump cycle (or immediately if no interp)
    if (defined $interp) {
        post_ui($interp, $code);
        return 0;
    }
    $code->();
    return 0;
}

# Yield from the current fiber if running inside an MT::Fiber.
sub fiber_yield {
    if ($HAS_FIBER && defined(&MT::Fiber::current) && MT::Fiber::current() > 0) {
        MT::Fiber::pass();
        return 1;
    }
    return 0;
}

# Pump scheduled MT::Fiber tasks cooperatively. Returns number of fibers finished (or 0).
sub pump_fibers {
    return 0 unless $HAS_FIBER;
    my $count = defined(&MT::Fiber::count) ? MT::Fiber::count() : 0;
    return 0 unless $count > 0;
    # Only run if we are not already inside a fiber
    if (defined(&MT::Fiber::current) && MT::Fiber::current() > 0) {
        MT::Fiber::pass();
        return 0;
    }
    return MT::Fiber::run();
}

# Create a channel (MT::Channel on perl5-mt, in-process FallbackChannel on stock Perl 5).
sub create_channel {
    my ($capacity, $name) = @_;
    $capacity = 64 unless defined $capacity;
    if ($HAS_CHANNEL) {
        if (defined $name && length $name) {
            return MT::Channel->named($name, $capacity);
        }
        return MT::Channel->new($capacity);
    }
    return Tcl::Tk::MT::Dispatch::FallbackChannel->new($capacity, $name);
}

# Attach an MT::Channel (or FallbackChannel) to an interp so MainLoop drains it on the UI thread.
sub attach_channel {
    my ($interp, $chan, $cb, %opts) = @_;
    die "attach_channel requires a channel object" unless defined $chan && ref($chan);
    die "attach_channel requires a CODE callback" unless ref($cb) eq 'CODE';
    my $key = _interp_key($interp);
    my $sub_id = $NEXT_SUB_ID++;
    push @{ $CHANNELS{$key} }, {
        id       => $sub_id,
        chan     => $chan,
        cb       => $cb,
        max      => $opts{max_per_tick} || 64,
        on_close => $opts{on_close},
    };
    return $sub_id;
}

sub detach_channel {
    my ($interp, $sub_id) = @_;
    my $key = _interp_key($interp);
    my $list = $CHANNELS{$key} or return 0;
    my $before = scalar @$list;
    @$list = grep { $_->{id} != $sub_id } @$list;
    delete $CHANNELS{$key} unless @$list;
    return $before - scalar(@$list);
}

# Drain all attached channels for $interp (non-blocking via try_recv).
sub pump_channels {
    my ($interp) = @_;
    my $key = _interp_key($interp);
    my $list = $CHANNELS{$key} or return 0;
    my $total = 0;
    for my $sub (@$list) {
        my $chan = $sub->{chan};
        my $cb   = $sub->{cb};
        my $max  = $sub->{max};
        my $n    = 0;
        while ($n < $max) {
            my ($ok, $val) = $chan->try_recv;
            last unless $ok;
            $cb->($val);
            $n++;
            $total++;
        }
    }
    return $total;
}

# Drain any queued UI callbacks for $interp.
sub pump_ui_queue {
    my ($interp) = @_;
    my $key = _interp_key($interp);
    my $q = $UI_QUEUE{$key} or return 0;
    return 0 unless @$q;
    my @batch = splice @$q;
    for my $cb (@batch) {
        $cb->();
    }
    return scalar @batch;
}

# One cooperative pump tick: MPSC Tcl marshal queue + UI callbacks + channels + MT::Fibers.
sub pump_once {
    my ($interp) = @_;
    my $work = 0;
    if (defined $interp && $interp->can('drain_marshal_queue')) {
        $work += $interp->drain_marshal_queue() || 0;
    }
    $work += pump_ui_queue($interp);
    $work += pump_channels($interp);
    $work += pump_fibers();
    return $work;
}

# Install the cooperative pump hook on a Tcl::MT interpreter.
sub install_idle_hook {
    my ($interp) = @_;
    return unless defined $interp && $interp->can('set_idle_hook');
    my $key = _interp_key($interp);
    return if $PUMP_HOOKED{$key};
    $PUMP_HOOKED{$key} = 1;
    weaken(my $weak_interp = $interp);
    $interp->set_idle_hook(sub {
        return unless defined $weak_interp;
        pump_once($weak_interp);
    });
    return 1;
}

# Check if any channels, UI callbacks, or fibers have pending work.
sub has_pending_work {
    my ($interp) = @_;
    my $key = _interp_key($interp);
    return 1 if $UI_QUEUE{$key} && @{ $UI_QUEUE{$key} };
    if ($CHANNELS{$key}) {
        for my $sub (@{ $CHANNELS{$key} }) {
            return 1 if $sub->{chan}->len > 0;
        }
    }
    if ($HAS_FIBER && defined(&MT::Fiber::count) && MT::Fiber::count() > 0) {
        return 1;
    }
    return 0;
}

sub cleanup_interp {
    my ($interp) = @_;
    my $key = _interp_key($interp);
    delete $CHANNELS{$key};
    delete $UI_QUEUE{$key};
    delete $PUMP_HOOKED{$key};
}

# Pure-Perl fallback channel when running on stock Perl 5 without MT::Channel.
package Tcl::Tk::MT::Dispatch::FallbackChannel;

my $NEXT_FB_ID = 100000;
my %NAMED_FB;

sub new {
    my ($class, $capacity, $name) = @_;
    $capacity = 64 unless defined $capacity;
    if (defined $name && length $name && exists $NAMED_FB{$name}) {
        return $NAMED_FB{$name};
    }
    my $self = bless {
        id       => $NEXT_FB_ID++,
        name     => $name,
        capacity => $capacity,
        buf      => [],
        closed   => 0,
    }, $class;
    $NAMED_FB{$name} = $self if defined $name && length $name;
    return $self;
}

sub id   { $_[0]{id} }
sub name { $_[0]{name} }
sub len  { scalar @{ $_[0]{buf} } }

sub send {
    my ($self, $val) = @_;
    die "send on closed channel" if $self->{closed};
    push @{ $self->{buf} }, $val;
    return 1;
}

sub recv {
    my ($self) = @_;
    return shift @{ $self->{buf} } if @{ $self->{buf} };
    return undef;
}

sub try_recv {
    my ($self) = @_;
    if (@{ $self->{buf} }) {
        return (1, shift @{ $self->{buf} });
    }
    return (0);
}

sub close {
    my ($self) = @_;
    $self->{closed} = 1;
    return 1;
}

1;

__END__

=head1 NAME

Tcl::Tk::MT::Dispatch - perl5-mt fiber pumping, UI-thread marshaling, and channel streaming

=head1 SYNOPSIS

    use Tcl::Tk::MT::Dispatch;

    my $ch = Tcl::Tk::MT::Dispatch::create_channel(64);
    my $id = Tcl::Tk::MT::Dispatch::attach_channel($interp, $ch, sub {
        my ($msg) = @_;
        ...
    });
    Tcl::Tk::MT::Dispatch::schedule_fiber(sub {
        Tcl::Tk::MT::Dispatch::fiber_yield();
    }, $interp);
    Tcl::Tk::MT::Dispatch::pump_once($interp);

=head1 DESCRIPTION

Integrates L<MT::Fiber>, L<MT::Channel>, and L<Tcl::MT>'s lock-free MPSC marshal
queue with the Tk event loop. Falls back to in-process queues on stock Perl 5
when C<MT::*> modules are absent.

=head1 FUNCTIONS

=over 4

=item C<has_mt()>, C<has_fiber()>, C<has_channel()>, C<has_pool()>, C<has_packed_av()>

Return 1 if the corresponding C<perl5-mt> capability is loaded, 0 otherwise.

=item C<is_ui_thread($interp)>

Return true if called on the interpreter's owning UI thread.

=item C<marshal_tcl($interp, $script, $sync)> / C<marshal_icall($interp, $sync, @args)>

Execute directly on the UI thread or marshal through the MPSC queue when called off-thread.

=item C<post_ui($interp, $coderef)>

Queue a Perl callback to run on the UI thread during the next pump cycle.

=item C<schedule_fiber($coderef, $interp)> / C<fiber_yield()> / C<pump_fibers()>

Schedule, yield, and cooperatively pump C<MT::Fiber> tasks (or UI-queue callbacks on stock Perl).

=item C<create_channel($capacity, $name)> / C<attach_channel($interp, $chan, $cb, %opts)> / C<detach_channel($interp, $sub_id)>

Create an C<MT::Channel> (or C<FallbackChannel>) and attach non-blocking UI-thread consumers.

=item C<pump_once($interp)> / C<pump_channels($interp)> / C<pump_ui_queue($interp)> / C<has_pending_work($interp)>

Drain marshaled Tcl calls, UI callbacks, attached channels, and cooperative fibers.

=item C<install_idle_hook($interp)> / C<cleanup_interp($interp)>

Attach or clean up per-interpreter dispatch hooks.

=back

=head1 SEE ALSO

L<Tcl::MT>, L<Tcl::Tk::MT>.

=cut
