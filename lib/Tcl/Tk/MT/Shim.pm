package Tcl::Tk::MT::Shim;

use strict;
use warnings;

our $VERSION = '0.01';
our $INSTALLED = 0;

sub is_installed { $INSTALLED }

sub install {
    return 1 if $INSTALLED;
    require Tcl::MT;
    require Tcl::Tk::MT;
    require Tcl::Tk::MT::Canvas;

    my $tcl_file = $INC{'Tcl/MT.pm'}     || __FILE__;
    my $mt_file  = $INC{'Tcl/Tk/MT.pm'}  || __FILE__;
    $INC{'Tcl.pm'}                       = $tcl_file;
    $INC{'Tcl/Tk.pm'}                    = $mt_file;
    $INC{'Tcl/pTk.pm'}                   = $mt_file;
    $INC{'Tcl/Tk/Widget.pm'}             = $mt_file;
    $INC{'Tcl/Tk/Widget/MainWindow.pm'}  = $mt_file;
    $INC{'Tcl/Tk/Widget/Canvas.pm'}      = $INC{'Tcl/Tk/MT/Canvas.pm'} || $mt_file;
    $INC{'Tcl/Tk/Widget/Menu.pm'}        = $mt_file;

    no strict 'refs';
    no warnings 'redefine', 'once';

    ${'Tcl::VERSION'} = '1.50';
    @{'Tcl::ISA'}     = ('Tcl::MT');
    *{'Tcl::Ev'}      = \&Tcl::Tk::MT::Ev;

    for my $ns ('Tcl::Tk', 'Tcl::pTk') {
        ${"${ns}::VERSION"}   = ($ns eq 'Tcl::Tk') ? '1.53' : '1.11';
        @{"${ns}::ISA"}       = ('Tcl::Tk::MT');
        @{"${ns}::EXPORT"}    = @Tcl::Tk::MT::EXPORT;
        @{"${ns}::EXPORT_OK"} = @Tcl::Tk::MT::EXPORT_OK;

        for my $sym (qw(
            import new new_interp MainWindow tkinit mainwindow
            MainLoop Exists Ev DoOneEvent update after afterCancel
            fileevent waitVariable interp widget_by_path widget widget_data
            Declare Eval icall call pkg_require
        )) {
            *{"${ns}::$sym"} = \&{"Tcl::Tk::MT::$sym"}
                if defined &{"Tcl::Tk::MT::$sym"};
        }
    }

    # Ensure $w->isa('Tcl::Tk::Widget') succeeds for all Tcl::Tk::MT widgets
    unless (grep { $_ eq 'Tcl::Tk::Widget' } @{'Tcl::Tk::MT::Widget::ISA'}) {
        push @{'Tcl::Tk::MT::Widget::ISA'}, 'Tcl::Tk::Widget';
    }

    # Alias widget classes
    @{'Tcl::Tk::MainWindow::ISA'}         = ('Tcl::Tk::MT::MainWindow');
    @{'Tcl::Tk::Widget::MainWindow::ISA'} = ('Tcl::Tk::MT::MainWindow');
    @{'Tcl::Tk::Widget::Canvas::ISA'}     = ('Tcl::Tk::MT::Canvas');
    @{'Tcl::Tk::Widget::Menu::ISA'}       = ('Tcl::Tk::MT::Widget');
    @{'Tcl::pTk::MainWindow::ISA'}        = ('Tcl::Tk::MT::MainWindow');
    @{'Tcl::pTk::Widget::ISA'}            = ('Tcl::Tk::MT::Widget');

    $INSTALLED = 1;
    $Tcl::Tk::MT::DROPIN_ACTIVE = 1;
    return 1;
}

1;

__END__

=head1 NAME

Tcl::Tk::MT::Shim - Compatibility shim aliasing Tcl::Tk and Tcl::pTk to Tcl::Tk::MT

=head1 SYNOPSIS

    perl -MTcl::Tk::MT=:dropin existing_tk_app.pl

=head1 DESCRIPTION

Populates C<%INC> entries for C<Tcl>, C<Tcl::Tk>, and C<Tcl::pTk> and aliases
their common entry points to L<Tcl::Tk::MT> so existing scripts can be tried
against C<Tcl::Tk::MT> without editing their C<use> lines.

The shim covers common C<Tcl::Tk> and C<Tcl::pTk> usage rather than every
internal method or third-party widget wrapper in those distributions.

=head1 FUNCTIONS

=over 4

=item C<install()>

Install the namespace and C<%INC> aliases (idempotent).

=item C<is_installed()>

Return 1 if the shim has been installed, 0 otherwise.

=back

=head1 SEE ALSO

L<Tcl::Tk::MT>, L<Tcl::MT>, and the upstream C<Tcl>, C<Tcl::Tk>, and
C<Tcl::pTk> distributions on CPAN.

=cut
