package Tcl::Tk::MT::Surface;

use strict;
use warnings;
use Scalar::Util qw(blessed);

use Tcl::Tk::MT ();
use Tcl::Tk::MT::Gfx ();

our $VERSION = '0.01';
our @ISA     = ('Tcl::Tk::MT::Widget');

sub new {
    my ($class, $parent, @args) = @_;

    unless (defined $parent && blessed($parent) && $parent->can('interp') && $parent->can('path')) {
        die "Tcl::Tk::MT::Surface->new requires a parent Tcl::Tk::MT::Widget";
    }

    my $w = 320;
    my $h = 240;
    my @tk_opts;

    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        my $v = ($i < @args) ? $args[$i++] : undef;
        my $lk = defined($k) ? $k : '';
        $lk =~ s/\A-//;
        if ($lk eq 'width') {
            $w = defined($v) ? int($v) : 320;
        }
        elsif ($lk eq 'height') {
            $h = defined($v) ? int($v) : 240;
        }
        else {
            push @tk_opts, ($k, $v);
        }
    }

    $w = 1 if $w < 1;
    $h = 1 if $h < 1;

    my $interp     = $parent->interp;
    my $path       = Tcl::Tk::MT::_next_widget_path($parent->path, 's');
    my $interp_ptr = $interp->raw_interp_ptr();
    my $surf_ptr   = Tcl::Tk::MT::Gfx::surface_create_raw($interp_ptr, $path, $w, $h);

    if (@tk_opts) {
        my @norm = Tcl::Tk::MT::_prepare_opts($interp, @tk_opts);
        my $ok = eval { $interp->icall($path, 'configure', @norm); 1 };
        if (!$ok) {
            my $err = $@;
            eval { Tcl::Tk::MT::Gfx::surface_destroy_raw($surf_ptr) };
            eval { $interp->icall('destroy', $path) };
            die $err;
        }
    }

    my $self = bless {
        interp       => $interp,
        path         => $path,
        parent       => $parent,
        kind         => 'tkmt_surface',
        _surface_ptr => $surf_ptr,
        _req_width   => $w,
        _req_height  => $h,
    }, $class;

    Tcl::Tk::MT::_register_widget($interp, $path, $self);
    return $self;
}

sub surface_ptr {
    my ($self) = @_;
    return $self->{_surface_ptr} || 0;
}

sub native_info {
    my ($self) = @_;
    my $info = Tcl::Tk::MT::Gfx::surface_native_info($self->{_surface_ptr} || 0);
    if ($self->{_surface_ptr} && !$info->{visible} && $info->{width} <= 1 && $info->{height} <= 1) {
        my $rw = eval { int($self->{interp}->icall_scalar('winfo', 'reqwidth',  $self->{path})) } || $self->{_req_width};
        my $rh = eval { int($self->{interp}->icall_scalar('winfo', 'reqheight', $self->{path})) } || $self->{_req_height};
        $info->{width}  = $rw if defined($rw) && $rw > 1;
        $info->{height} = $rh if defined($rh) && $rh > 1;
    }
    return $info;
}

sub set_ext_geometry_cb {
    my ($self, $ud_ptr, $on_geom_fn_ptr, $on_detach_fn_ptr) = @_;
    return Tcl::Tk::MT::Gfx::surface_set_ext_geometry_cb(
        $self->{_surface_ptr} || 0,
        $ud_ptr           // 0,
        $on_geom_fn_ptr   // 0,
        $on_detach_fn_ptr // 0,
    );
}

sub clear_ext_geometry_cb {
    my ($self) = @_;
    return $self->set_ext_geometry_cb(0, 0, 0);
}

sub request_redraw {
    my ($self) = @_;
    if (my $ptr = $self->{_surface_ptr}) {
        Tcl::Tk::MT::Gfx::surface_request_redraw($ptr);
    }
    return;
}

sub destroy {
    my ($self) = @_;
    if (my $ptr = $self->{_surface_ptr}) {
        $self->{_surface_ptr} = 0;
        eval { Tcl::Tk::MT::Gfx::surface_destroy_raw($ptr) };
    }
    if (defined $self->{interp} && defined $self->{path}) {
        return if ref($self->{interp}) eq 'HASH' && $self->{interp}{_destroyed};
        return $self->SUPER::destroy();
    }
    return;
}

sub DESTROY {
    my ($self) = @_;
    if (my $ptr = $self->{_surface_ptr}) {
        $self->{_surface_ptr} = 0;
        eval { Tcl::Tk::MT::Gfx::surface_destroy_raw($ptr) };
    }
    return;
}

1;

__END__

=head1 NAME

Tcl::Tk::MT::Surface - Native Tk host surface widget for external renderers

=head1 SYNOPSIS

    use Tcl::Tk::MT;

    my $mw   = MainWindow->new(-title => 'Surface');
    my $surf = $mw->Surface(-width => 1280, -height => 720, -bg => '#0a0e14')
                  ->pack(-fill => 'both', -expand => 1);

    my $info = $surf->native_info();
    # $info->{platform} is 'cocoa', 'x11', 'win32', or 'none'
    # $info->{view_ptr}, $info->{display_ptr}, $info->{window_id},
    # $info->{x}, $info->{y}, $info->{width}, $info->{height},
    # $info->{scale}, $info->{visible}, $info->{surface_ptr}, $info->{realized}

    my $ptr = $surf->surface_ptr();
    Tcl::Tk::MT::Gfx::surface_set_ext_geometry_cb(
        $ptr, $userdata_ptr, $on_geom_fn_ptr, $on_detach_fn_ptr
    );

=head1 DESCRIPTION

C<Tcl::Tk::MT::Surface> is a subclass of C<Tcl::Tk::MT::Widget> wrapping a Tk
C<frame> together with a native surface handle tracker (C<tkmt_surface_t>).
It allows external XS renderers (such as Metal, Vulkan, OpenGL, or Direct3D
extensions) to obtain the platform window handle and receive geometry,
visibility, and detach notifications without linking against the C<Tcl::Tk::MT>
shared library.

Because it inherits from C<Tcl::Tk::MT::Widget>, standard geometry managers
(C<pack>, C<grid>, C<place>), event bindings (C<bind>), widget configuration
(C<configure>, C<cget>), focus, C<winfo>, and string/boolean overloading work
as with any other Tk widget.

=head1 METHODS

=over 4

=item C<< Tcl::Tk::MT::Surface->new($parent, %opts) >>

Create a surface host frame under C<$parent>. C<-width> and C<-height> default
to C<320> and C<240>. Any additional options (such as C<-bg>, C<-background>,
C<-cursor>, or C<-takefocus>) are forwarded to the underlying Tk C<frame>.
Normally invoked via C<< $parent->Surface(...) >>.

=item C<< $surf->native_info() >>

Query the current native handle and geometry and return a hashref with keys:

=over 4

=item C<platform>

Platform tag: C<'cocoa'>, C<'x11'>, C<'win32'>, or C<'none'>.

=item C<view_ptr>

Raw C<uintptr_t> (C<UV>) of the native view (macOS C<NSView*>, Win32 C<HWND>,
or C<0>).

=item C<display_ptr>

Raw C<uintptr_t> (C<UV>) of the X11 C<Display*>, or C<0> on other platforms.

=item C<window_id>

Native window identifier (X11 C<Window> XID, Win32 C<HWND>, macOS C<NSView*>,
or C<0>).

=item C<x>, C<y>

Logical origin in pixels relative to the enclosing toplevel content area.

=item C<width>, C<height>

Logical dimensions in pixels.

=item C<scale>

Backing scale factor (for example, C<2.0> on HiDPI displays, C<1.0> otherwise).

=item C<visible>

C<1> if the widget and all ancestors up to the toplevel are mapped and visible,
C<0> otherwise.

=item C<surface_ptr>

Raw C<uintptr_t> (C<UV>) of the underlying C<tkmt_surface_t*>, or C<0> after
destruction.

=item C<realized>

C<1> if the platform native handle has been realized, C<0> otherwise.

=back

=item C<< $surf->surface_ptr() >>

Return the raw C<uintptr_t> (C<UV>) of the underlying C<tkmt_surface_t*>, or
C<0> if the surface has been destroyed.

=item C<< $surf->set_ext_geometry_cb($ud_ptr, $on_geom_fn_ptr, $on_detach_fn_ptr) >>

Attach C function pointers (passed as C<UV> addresses) to receive live geometry
and detach callbacks via C<Tcl::Tk::MT::Gfx::surface_set_ext_geometry_cb>.
Returns C<1> on success or C<0> if the surface has been destroyed.

The expected C signatures are:

    typedef void (*tkmt_surface_geometry_fn)(
        void *userdata, int x, int y, int width, int height, int visible
    );
    typedef void (*tkmt_surface_detach_fn)(void *userdata);

When C<$on_geom_fn_ptr> is non-zero, it is invoked immediately with the current
geometry and again whenever the frame or an ancestor is configured, mapped,
unmapped, exposed, or destroyed. C<$on_detach_fn_ptr>, if non-zero, is invoked
if the surface is destroyed while still attached.

=item C<< $surf->clear_ext_geometry_cb() >>

Unregister any attached external geometry and detach callbacks.

=item C<< $surf->request_redraw() >>

Coalesce a redraw request on the underlying surface via C<Tcl_DoWhenIdle>.

=item C<< $surf->destroy() >>

Detach and release the C<tkmt_surface_t> handle (invoking any registered detach
callback first) and destroy the underlying Tk frame widget.

=back

=head1 LOW-LEVEL XS INTERFACE

C<Tcl::Tk::MT::Gfx> exposes the raw handle functions used by this class:

=over 4

=item C<Tcl::Tk::MT::Gfx::surface_create_raw($interp_ptr, $widget_path, $width, $height)>

=item C<Tcl::Tk::MT::Gfx::surface_destroy_raw($surface_ptr)>

=item C<Tcl::Tk::MT::Gfx::surface_native_info($surface_ptr)>

=item C<Tcl::Tk::MT::Gfx::surface_set_ext_geometry_cb($surface_ptr, $ud_ptr, $on_geom_fn_ptr, $on_detach_fn_ptr)>

=item C<Tcl::Tk::MT::Gfx::surface_request_redraw($surface_ptr)>

=back

=head1 AUTHOR

stratum42

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as Perl 5 itself.

=head1 SEE ALSO

L<Tcl::Tk::MT>, L<Tcl::Tk::MT::Gfx>, L<Tcl::Tk::MT::Canvas>.

=cut
