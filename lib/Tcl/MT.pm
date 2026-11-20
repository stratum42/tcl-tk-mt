package Tcl::MT;
use strict;
use warnings;

our $VERSION = '0.01';

use Exporter 'import';
our @EXPORT_OK = qw(
    DONT_WAIT WINDOW_EVENTS FILE_EVENTS TIMER_EVENTS IDLE_EVENTS ALL_EVENTS
);

require XSLoader;
XSLoader::load('Tcl::MT', $VERSION);

sub new {
    my ($class, %opts) = @_;
    my $init_tk = $opts{init_tk} ? 1 : 0;
    my $ptr = _xs_create($init_tk);
    return bless {
        _ptr       => $ptr,
        _idle_hook => undef,
        _destroyed => 0,
    }, $class;
}

sub new_tk {
    my ($class, %opts) = @_;
    return $class->new(%opts, init_tk => 1);
}

sub set_idle_hook {
    my ($self, $cb) = @_;
    $self->{_idle_hook} = $cb;
    return $self;
}

sub MainLoop {
    my ($self) = @_;
    if (defined $ENV{TCL_TK_MT_AUTO_EXIT_MS}
        && $ENV{TCL_TK_MT_AUTO_EXIT_MS} =~ /\A\d+\z/
        && $ENV{TCL_TK_MT_AUTO_EXIT_MS} > 0)
    {
        eval { $self->icall('after', int($ENV{TCL_TK_MT_AUTO_EXIT_MS}), 'destroy', '.') };
    }
    my $hook = $self->{_idle_hook};
    if ($hook) {
        while ($self->num_main_windows() > 0) {
            my $did = $self->DoOneEvent(ALL_EVENTS() | DONT_WAIT());
            my $more = $hook->($self);
            if (!$did && !$more) {
                $self->DoOneEvent(ALL_EVENTS());
            }
        }
    } else {
        while ($self->num_main_windows() > 0) {
            $self->DoOneEvent(ALL_EVENTS());
        }
    }
    return;
}

sub pkg_require {
    my ($self, $pkg, $ver) = @_;
    my $res = eval {
        defined $ver
            ? $self->icall_scalar('package', 'require', $pkg, $ver)
            : $self->icall_scalar('package', 'require', $pkg)
    };
    return $@ ? undef : $res;
}

sub after {
    my ($self, @args) = @_;
    return $self->icall_scalar('after', @args);
}

sub afterCancel {
    my ($self, $id) = @_;
    return $self->icall('after', 'cancel', $id);
}

sub update {
    my ($self, $mode) = @_;
    return defined($mode) ? $self->icall('update', $mode) : $self->icall('update');
}

sub bind {
    my ($self, @args) = @_;
    return $self->icall('bind', @args);
}

sub pack {
    my ($self, @args) = @_;
    return $self->icall('pack', @args);
}

sub grid {
    my ($self, @args) = @_;
    return $self->icall('grid', @args);
}

sub place {
    my ($self, @args) = @_;
    return $self->icall('place', @args);
}

sub wm {
    my ($self, @args) = @_;
    return $self->icall('wm', @args);
}

sub winfo {
    my ($self, @args) = @_;
    return $self->icall('winfo', @args);
}

sub create_surface {
    my ($self, $widget_path, $width, $height) = @_;
    $width  //= 320;
    $height //= 240;
    my $ptr = $self->_xs_create_surface($widget_path, $width, $height);
    return bless {
        _ptr       => $ptr,
        _interp    => $self,
        _destroyed => 0,
    }, 'Tcl::MT::Surface';
}

sub destroy {
    my ($self) = @_;
    return if $self->{_destroyed};
    $self->{_destroyed} = 1;
    if (my $ptr = delete $self->{_ptr}) {
        _xs_destroy($ptr);
    }
    return;
}

sub DESTROY {
    my ($self) = @_;
    $self->destroy();
}

package Tcl::MT::Surface;
use strict;
use warnings;

sub ptr {
    my ($self) = @_;
    return $self->{_ptr} || 0;
}

sub destroy {
    my ($self) = @_;
    return if $self->{_destroyed};
    $self->{_destroyed} = 1;
    if (my $ptr = delete $self->{_ptr}) {
        _xs_destroy_surface($ptr);
    }
    delete $self->{_interp};
    return;
}

sub DESTROY {
    my ($self) = @_;
    $self->destroy();
}

1;

__END__

=head1 NAME

Tcl::MT - C11 XS bridge to Tcl/Tk (8.6 and 9.x) for perl5-mt and Perl 5

=head1 SYNOPSIS

    use Tcl::MT qw(DONT_WAIT ALL_EVENTS);

    my $interp = Tcl::MT->new();
    my $sum = $interp->icall('expr', '2 + 2');

    # With Tk:
    my $tk   = Tcl::MT->new_tk();
    my $surf = $tk->create_surface('.canvas_host', 800, 600);

=head1 DESCRIPTION

C<Tcl::MT> is a C11 XS bridge to Tcl/Tk 8.6 and 9.x. It compiles with
C<PERL_NO_GET_CONTEXT> and C<PERL_XS_THREADSAFE> for C<perl5-mt> while
remaining compatible with stock Perl 5.16+. It provides direct
C<SV E<lt>-E<gt> Tcl_Obj> evaluation via C<Tcl_EvalObjv>, an interned
C<Tcl_Obj*> cache for commands and options, an owning UI-thread check,
a lock-free MPSC marshal queue for cross-thread evaluation, and native
Tk host surface extraction.

Because Tcl and Tk interpreters are bound to the OS thread that creates
them, direct calls such as C<Eval> and C<icall> must run on that owning
thread; other threads should use C<marshal_eval_async> or
C<marshal_eval_sync>.

=head1 EXPORTS

None by default. Optional event-loop flag constants (C<@EXPORT_OK>):
C<DONT_WAIT>, C<WINDOW_EVENTS>, C<FILE_EVENTS>, C<TIMER_EVENTS>,
C<IDLE_EVENTS>, C<ALL_EVENTS>.

=head1 METHODS

=over 4

=item C<< Tcl::MT->new(init_tk => $bool) >> / C<< Tcl::MT->new_tk() >>

Create a Tcl interpreter on the calling (UI) thread. C<new_tk()> initializes
Tk immediately; C<Init()> initializes Tk on an existing interpreter.

=item C<< $interp->Eval($script) >>

Evaluate a Tcl script on the owning UI thread and return the string result.

=item C<< $interp->icall($cmd, @args) >> / C<call> / C<icall_scalar> / C<icall_list>

Invoke a Tcl command directly via C<Tcl_EvalObjv> without string quoting.
Arrayrefs convert to Tcl lists (using zero-copy packed AV readers when
available); code refs are registered as Tcl command callbacks.

=item C<< $interp->CreateCommand($name, $coderef) >> / C<< $interp->DeleteCommand($name) >>

Register or remove a Perl callback callable as a Tcl command.

=item C<< $interp->GetVar($name, $flags) >> / C<SetVar> / C<GetVar2> / C<SetVar2> / C<UnsetVar>

Read, write, or unset Tcl scalar and array variables.

=item C<< $interp->DoOneEvent($flags) >> / C<< $interp->MainLoop() >> / C<< $interp->set_idle_hook($coderef) >>

Pump the Tcl/Tk event loop and drain the MPSC marshal queue.

=item C<< $interp->marshal_eval_async($script) >> / C<< $interp->marshal_eval_sync($script) >> / C<< $interp->drain_marshal_queue() >>

Thread-safe evaluation marshaling from worker threads onto the owning UI thread.

=item C<< $interp->is_owner_thread() >> / C<owner_tid> / C<has_tk> / C<num_main_windows> / C<intern_count> / C<marshal_count> / C<raw_interp_ptr>

Interpreter state and diagnostic accessors.

=item C<< $interp->create_surface($widget_path, $width, $height) >>

Create a Tk host frame and return a C<Tcl::MT::Surface> handle supporting
C<ptr()>, C<path()>, C<native_info()>, C<request_redraw()>,
C<place_child()>, C<remove_child()>, and C<destroy()>.

=item C<< $interp->blit_rgba_photo($photo_name, $rgba_data, $width, $height) >>

Blit packed RGBA8888 pixels (byte string or packed U8 arrayref) into a Tk Photo image.

=item C<< $interp->destroy() >>

Destroy the interpreter and release associated resources.

=back

=head1 FUNCTIONS

C<tcl_version()>, C<is_perl5_mt()>, C<have_packed_av()>, C<current_tid()>.

=head1 ACKNOWLEDGMENTS

Built in the tradition of the CPAN C<Tcl> distribution by Vadim Konovalov,
Christopher Chavez, and the contributors to C<Tcl>, Tcl/Tk, and Perl 5.

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as Perl 5 itself.

=cut
