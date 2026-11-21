package Tcl::Tk::MT;

use strict;
use warnings;
use Scalar::Util qw(blessed refaddr weaken);

use Tcl::MT ();
use Tcl::Tk::MT::Dispatch ();

our $VERSION       = '0.01';
our $DROPIN_ACTIVE = 0;

our @EXPORT    = qw(MainWindow MainLoop Exists Ev tkinit new_interp);
our @EXPORT_OK = qw(
    MainWindow MainLoop Exists Ev tkinit new_interp
    DoOneEvent update after afterCancel fileevent waitVariable
    mainwindow interp widget_by_path widget widget_data Declare
);

my @PERLTK_EXPORT = qw(
    MainWindow MainLoop Exists Ev tkinit
    DoOneEvent update after afterCancel fileevent waitVariable mainwindow
);

my @WIDGET_EXPORT_NAMES = qw(
    button label entry frame scrollbar menu toplevel text
    checkbutton radiobutton listbox scale spinbox labelframe
    panedwindow message menubutton canvas
);

# Track the default/most-recent interpreter and widget registry
our $DEFAULT_INTERP;
my %WIDGET_REGISTRY;    # "$interp_addr:$path" => weakened widget ref
my %WIDGET_DATA;        # "$interp_addr:$path" => {}
my %OPTION_CACHE;       # "text" => "-text", "-text" => "-text"
my $WIDGET_SEQ = 0;
my $VAR_SEQ    = 0;
my %LINKED_VARS;        # "$interp_addr:$sv_addr" => $tcl_var_name
my %TCL_VAR_TO_REF;     # "$interp_addr:$tcl_var_name" => \$sv

sub import {
    my ($class, @args) = @_;
    my $caller = caller;

    my @to_export;
    my @widget_exports;
    my $want_default = (@args == 0);

    for my $arg (@args) {
        if ($arg eq ':dropin') {
            require Tcl::Tk::MT::Shim;
            Tcl::Tk::MT::Shim::install();
        }
        elsif ($arg eq ':perlTk') {
            push @to_export, @PERLTK_EXPORT;
        }
        elsif ($arg eq ':widgets') {
            push @widget_exports, @WIDGET_EXPORT_NAMES;
        }
        elsif ($arg eq ':all' || $arg eq ':ALL' || $arg eq ':misc') {
            push @to_export, @EXPORT_OK;
        }
        elsif ($arg eq ':default') {
            $want_default = 1;
        }
        else {
            push @to_export, $arg;
        }
    }
    @to_export = @EXPORT if $want_default && !@to_export && !@widget_exports;

    no strict 'refs';
    for my $sym (@to_export) {
        if (defined &{"Tcl::Tk::MT::$sym"}) {
            *{"${caller}::$sym"} = \&{"Tcl::Tk::MT::$sym"};
        }
        else {
            die "Tcl::Tk::MT does not export '$sym'";
        }
    }
    for my $wcmd (@widget_exports) {
        my $tcl_cmd = $wcmd;
        *{"${caller}::$wcmd"} = sub {
            my ($path, @wargs) = @_;
            my $interp = $DEFAULT_INTERP || Tcl::MT->new_tk();
            $DEFAULT_INTERP = $interp;
            my @norm = _prepare_opts($interp, @wargs);
            $interp->icall($tcl_cmd, $path, @norm);
            return widget($interp, $path, $tcl_cmd);
        };
    }
    return 1;
}

# Fast cached option key normalization (no regex in hot path).
sub _norm_opt {
    my ($k) = @_;
    return $OPTION_CACHE{$k} if exists $OPTION_CACHE{$k};
    my $norm = (substr($k, 0, 1) eq '-') ? $k : "-$k";
    $OPTION_CACHE{$k} = $norm;
    return $norm;
}

sub _normalize_opts {
    my @out;
    my $i = 0;
    my $n = scalar @_;
    while ($i < $n) {
        my $k = $_[$i++];
        push @out, (defined($k) && !ref($k) ? _norm_opt($k) : $k);
        push @out, $_[$i++] if $i < $n;
    }
    return @out;
}

my %CMD_OPT = map { $_ => 1 } qw(
    -command -yscrollcommand -xscrollcommand -validatecommand
    -invalidcommand -postcommand -browsecommand -tearoffcommand
);

sub _prepare_opts {
    my ($interp, @args) = @_;
    my @out;
    my $i = 0;
    my $n = scalar @args;
    while ($i < $n) {
        my $k = $args[$i++];
        my $nk = (defined($k) && !ref($k)) ? _norm_opt($k) : $k;
        push @out, $nk;
        if ($i < $n) {
            my $v = $args[$i++];
            if (defined $v && ref($v) eq 'SCALAR') {
                $v = _ensure_tcl_var($interp, $v);
            }
            elsif (defined $v && ref($v) eq 'ARRAY' && defined($nk) && !ref($nk) && $CMD_OPT{$nk} && @$v && ref($v->[0]) eq 'CODE') {
                my ($code, @extra) = @$v;
                $v = sub { $code->(@extra, @_) };
            }
            push @out, $v;
        }
    }
    return @out;
}

sub _next_widget_path {
    my ($parent_path, $prefix) = @_;
    my $seq = ++$WIDGET_SEQ;
    return ($parent_path eq '.') ? ".${prefix}${seq}" : "${parent_path}.${prefix}${seq}";
}

sub _register_widget {
    my ($interp, $path, $w) = @_;
    my $key = refaddr($interp) . ':' . $path;
    $WIDGET_REGISTRY{$key} = $w;
    weaken($WIDGET_REGISTRY{$key});
    return $w;
}

sub widget_by_path {
    my ($interp, $path) = @_;
    $interp = $DEFAULT_INTERP unless defined $interp;
    return undef unless defined $interp;
    return $WIDGET_REGISTRY{ refaddr($interp) . ':' . $path };
}

sub widget {
    my ($self_or_interp, $path, $type, @args) = @_;
    my $interp = (defined $self_or_interp && blessed($self_or_interp))
        ? ($self_or_interp->can('interp') ? $self_or_interp->interp : $self_or_interp)
        : $DEFAULT_INTERP;
    die "widget: no active Tcl::Tk::MT interpreter" unless defined $interp;

    if (defined(my $existing = widget_by_path($interp, $path))) {
        return $existing;
    }

    my $kind = defined($type) ? lc($type) : '';
    my $class = 'Tcl::Tk::MT::Widget';
    if ($path eq '.') {
        $class = 'Tcl::Tk::MT::MainWindow';
        $kind ||= 'mainwindow';
    }
    elsif ($kind eq 'menu') {
        $class = $DROPIN_ACTIVE ? 'Tcl::Tk::Widget::Menu' : 'Tcl::Tk::MT::Widget';
    }

    my $parent_path;
    if ($path ne '.' && $path =~ /\A(.*)\.([^.]+)\z/) {
        $parent_path = length($1) ? $1 : '.';
    }
    my $parent = defined($parent_path) ? widget_by_path($interp, $parent_path) : undef;

    my $w = bless {
        interp => $interp,
        path   => $path,
        parent => $parent,
        kind   => $kind,
    }, $class;
    return _register_widget($interp, $path, $w);
}

sub widget_data {
    my ($self, $path) = @_;
    my $interp;
    if (blessed($self)) {
        $interp = $self->can('interp') ? $self->interp : $self;
        $path = $self->path if !defined($path) && $self->can('path');
    }
    $interp ||= $DEFAULT_INTERP;
    $path   //= '.';
    my $key = (defined($interp) ? refaddr($interp) : 0) . ':' . $path;
    return ($WIDGET_DATA{$key} ||= {});
}

sub Declare {
    my ($self, $perl_name, $tcl_cmd, %opts) = @_;
    die "Declare requires perl widget name and Tcl command"
        unless defined $perl_name && length $perl_name && defined $tcl_cmd && length $tcl_cmd;
    my $require = $opts{'-require'} // $opts{require};
    my $prefix  = $opts{'-prefix'}  // $opts{prefix} // lc($perl_name);

    no strict 'refs';
    no warnings 'redefine';
    *{"Tcl::Tk::MT::Widget::$perl_name"} = sub {
        my ($wself, @args) = @_;
        my $interp = $wself->{interp};
        if (defined $require && length $require) {
            $interp->icall_scalar('package', 'require', $require);
        }
        my $path = Tcl::Tk::MT::_next_widget_path($wself->{path}, $prefix);
        my @norm = Tcl::Tk::MT::_prepare_opts($interp, @args);
        Tcl::Tk::MT::Dispatch::marshal_icall($interp, 1, $tcl_cmd, $path, @norm);
        my $w = bless {
            interp => $interp,
            path   => $path,
            parent => $wself,
            kind   => $tcl_cmd,
        }, 'Tcl::Tk::MT::Widget';
        return Tcl::Tk::MT::_register_widget($interp, $path, $w);
    };
    return 1;
}

sub new_interp {
    my ($class_or_opt, %opts) = @_;
    if (defined $class_or_opt && !ref($class_or_opt)
        && $class_or_opt ne 'Tcl::Tk::MT' && $class_or_opt ne 'Tcl::Tk' && $class_or_opt ne 'Tcl::pTk')
    {
        unshift @_, $class_or_opt;
        %opts = @_;
    }
    my $init_tk = exists $opts{init_tk} ? $opts{init_tk} : 1;
    my $interp  = $init_tk ? Tcl::MT->new_tk() : Tcl::MT->new(init_tk => 0);
    Tcl::Tk::MT::Dispatch::install_idle_hook($interp);
    $DEFAULT_INTERP = $interp;

    my $self = bless {
        interp => $interp,
        mw     => undef,
    }, 'Tcl::Tk::MT';
    return $self;
}

sub new {
    my ($class, @args) = @_;
    return new_interp($class, @args);
}

sub interp {
    my ($self) = @_;
    return ref($self) ? $self->{interp} : $DEFAULT_INTERP;
}

sub mainwindow {
    my ($self) = @_;
    if (ref($self) && $self->{mw}) {
        return $self->{mw};
    }
    my $interp = ref($self) ? $self->{interp} : ($DEFAULT_INTERP || Tcl::MT->new_tk());
    Tcl::Tk::MT::Dispatch::install_idle_hook($interp);
    $DEFAULT_INTERP = $interp;
    my $mw = Tcl::Tk::MT::MainWindow->_wrap_interp($interp);
    $self->{mw} = $mw if ref($self);
    return $mw;
}

sub MainWindow {
    if (@_ && (ref($_[0]) || $_[0] eq 'Tcl::Tk::MT' || $_[0] eq 'Tcl::Tk' || $_[0] eq 'Tcl::pTk')) {
        shift;
        return Tcl::Tk::MT::MainWindow->new(@_);
    }
    return 'Tcl::Tk::MT::MainWindow';
}

sub tkinit {
    return Tcl::Tk::MT::MainWindow->new(@_);
}

sub Ev {
    return bless [@_], 'Tcl::Tk::MT::Ev';
}

sub Exists {
    my ($w) = @_;
    return 0 unless defined $w;
    my $interp = (blessed($w) && $w->can('interp')) ? $w->interp : $DEFAULT_INTERP;
    return 0 unless defined $interp;
    my $path = (blessed($w) && $w->can('path')) ? $w->path : "$w";
    my $ok = eval { $interp->icall_scalar('winfo', 'exists', $path) };
    return $ok ? 1 : 0;
}

sub _extract_interp_arg {
    if (@_ && blessed($_[0]) && ($_[0]->isa('Tcl::Tk::MT') || $_[0]->isa('Tcl::MT'))) {
        my $obj = shift;
        return ($obj->isa('Tcl::MT') ? $obj : $obj->{interp}, @_);
    }
    return ($DEFAULT_INTERP, @_);
}

sub DoOneEvent {
    my ($interp, $flags) = _extract_interp_arg(@_);
    return 0 unless defined $interp;
    $flags = 0 unless defined $flags;
    Tcl::Tk::MT::Dispatch::pump_once($interp);
    return $interp->DoOneEvent($flags);
}

sub update {
    my ($interp, $idletasks) = _extract_interp_arg(@_);
    return unless defined $interp;
    Tcl::Tk::MT::Dispatch::pump_once($interp);
    if (defined $idletasks && $idletasks eq 'idletasks') {
        $interp->icall('update', 'idletasks');
    }
    else {
        $interp->icall('update');
    }
    Tcl::Tk::MT::Dispatch::pump_once($interp);
    return;
}

sub after {
    my ($interp, $ms, @rest) = _extract_interp_arg(@_);
    die "No active Tcl::Tk::MT interpreter" unless defined $interp;
    return $interp->icall_scalar('after', $ms, @rest);
}

sub afterCancel {
    my ($interp, $id) = _extract_interp_arg(@_);
    return unless defined $interp;
    return $interp->icall('after', 'cancel', $id);
}

sub fileevent {
    my ($interp, $fh, $mode, $cb) = _extract_interp_arg(@_);
    die "No active Tcl::Tk::MT interpreter" unless defined $interp;
    return $interp->icall('fileevent', $fh, $mode, defined($cb) ? $cb : '');
}

sub waitVariable {
    my ($interp, $varref) = _extract_interp_arg(@_);
    die "No active Tcl::Tk::MT interpreter" unless defined $interp;
    my $tcl_var = _ensure_tcl_var($interp, $varref);
    $interp->icall('tkwait', 'variable', $tcl_var);
    return;
}

for my $deleg (qw(
    Eval icall call icall_scalar icall_list
    GetVar SetVar GetVar2 SetVar2 UnsetVar
    CreateCommand DeleteCommand pkg_require
    bind pack grid place wm winfo
    Init has_tk num_main_windows
)) {
    no strict 'refs';
    *{"Tcl::Tk::MT::$deleg"} = sub {
        my ($self, @args) = @_;
        my $interp = (blessed($self) && $self->{interp}) ? $self->{interp} : $DEFAULT_INTERP;
        die "Tcl::Tk::MT::$deleg: no active interpreter" unless defined $interp;
        return $interp->$deleg(@args);
    };
}

our $AUTOLOAD;
sub AUTOLOAD {
    my ($self, @args) = @_;
    my $method = $AUTOLOAD;
    $method =~ s/\A.*:://;
    return if $method eq 'DESTROY';
    my $interp = (blessed($self) && $self->{interp}) ? $self->{interp} : $DEFAULT_INTERP;
    die "Tcl::Tk::MT::$method: no active interpreter" unless defined $interp;
    return $interp->icall($method, @args);
}

sub _ensure_tcl_var {
    my ($interp, $varref) = @_;
    return "$varref" unless ref($varref) eq 'SCALAR';
    my $iaddr = refaddr($interp);
    my $key   = $iaddr . ':' . refaddr($varref);
    if (exists $LINKED_VARS{$key}) {
        return $LINKED_VARS{$key};
    }
    my $init_val = defined($$varref) ? $$varref : '';
    my $name = '::tkmt_var_' . (++$VAR_SEQ);
    $interp->SetVar($name, $init_val);
    unless (tied($$varref)) {
        tie $$varref, 'Tcl::Tk::MT::Var', $interp, $name;
    }
    $LINKED_VARS{$key} = $name;
    $TCL_VAR_TO_REF{"$iaddr:$name"} = $varref;
    return $name;
}

sub _lookup_tcl_var_ref {
    my ($interp, $name) = @_;
    return undef unless defined $interp && defined $name;
    my $iaddr = refaddr($interp);
    return $TCL_VAR_TO_REF{"$iaddr:$name"}
        // $TCL_VAR_TO_REF{"$iaddr:::$name"};
}

# Cooperative MainLoop: pumps Tcl/Tk events, MPSC marshal queue, MT::Channels, and MT::Fibers.
sub MainLoop {
    my ($maybe_interp) = @_;
    my $interp = (defined $maybe_interp && blessed($maybe_interp))
        ? ($maybe_interp->can('interp') ? $maybe_interp->interp : $maybe_interp)
        : $DEFAULT_INTERP;
    die "MainLoop: no active Tcl::Tk::MT interpreter" unless defined $interp;

    if (defined $ENV{TCL_TK_MT_AUTO_EXIT_MS}
        && $ENV{TCL_TK_MT_AUTO_EXIT_MS} =~ /\A\d+\z/
        && $ENV{TCL_TK_MT_AUTO_EXIT_MS} > 0)
    {
        eval { $interp->icall('after', int($ENV{TCL_TK_MT_AUTO_EXIT_MS}), 'destroy', '.') };
    }

    Tcl::Tk::MT::Dispatch::install_idle_hook($interp);
    my $DONT_WAIT = eval { Tcl::MT::DONT_WAIT() } || 2;

    while ($interp->num_main_windows() > 0) {
        Tcl::Tk::MT::Dispatch::pump_once($interp);
        if (Tcl::Tk::MT::Dispatch::has_pending_work($interp)) {
            $interp->DoOneEvent($DONT_WAIT);
        }
        else {
            $interp->DoOneEvent(0);
        }
    }
    Tcl::Tk::MT::Dispatch::pump_once($interp);
    return;
}

# =============================================================================
# Tcl::Tk::MT::Var - Tied scalar linked to a Tcl variable
# =============================================================================
package Tcl::Tk::MT::Var;

use strict;
use warnings;
use Scalar::Util qw(weaken);

sub TIESCALAR {
    my ($class, $interp, $name) = @_;
    my $self = bless {
        interp => $interp,
        name   => $name,
    }, $class;
    weaken($self->{interp});
    return $self;
}

sub FETCH {
    my ($self) = @_;
    my $interp = $self->{interp} or return undef;
    return eval { $interp->GetVar($self->{name}) };
}

sub STORE {
    my ($self, $val) = @_;
    my $interp = $self->{interp} or return $val;
    $interp->SetVar($self->{name}, defined($val) ? $val : '');
    return $val;
}

# =============================================================================
# Tcl::Tk::MT::Widget - Base class for all Tk & ttk widgets (compiled dispatch)
# =============================================================================
package Tcl::Tk::MT::Widget;

use strict;
use warnings;
use Scalar::Util qw(blessed refaddr);
use overload
    '""'     => sub { $_[0]->{path} },
    'bool'   => sub { 1 },
    fallback => 1;

# Install all widget factory methods at compile time (zero AUTOLOAD overhead).
BEGIN {
    # Compiled widget constructors table: PerlMethodName => [ tcl_cmd, path_prefix ]
    my %WIDGET_FACTORIES = (
        # Classic Tk widgets
        Button      => [ 'button',          'b'   ],
        Label       => [ 'label',           'l'   ],
        Entry       => [ 'entry',           'e'   ],
        Frame       => [ 'frame',           'f'   ],
        Scrollbar   => [ 'scrollbar',       'sb'  ],
        Toplevel    => [ 'toplevel',        'tl'  ],
        Text        => [ 'text',            'txt' ],
        Checkbutton => [ 'checkbutton',     'cb'  ],
        Radiobutton => [ 'radiobutton',     'rb'  ],
        Listbox     => [ 'listbox',         'lb'  ],
        Scale       => [ 'scale',           'sc'  ],
        Spinbox     => [ 'spinbox',         'sp'  ],
        Labelframe  => [ 'labelframe',      'lf'  ],
        LabelFrame  => [ 'labelframe',      'lf'  ],
        Panedwindow => [ 'panedwindow',     'pw'  ],
        Message     => [ 'message',         'msg' ],

        # ttk widgets (ttk*, Ttk*, and Tk-style aliases)
        Notebook       => [ 'ttk::notebook',    'nb'  ],
        Treeview       => [ 'ttk::treeview',    'tv'  ],
        ttkButton      => [ 'ttk::button',      'tb'  ],
        ttkLabel       => [ 'ttk::label',       'tlb' ],
        ttkEntry       => [ 'ttk::entry',       'te'  ],
        ttkFrame       => [ 'ttk::frame',       'tf'  ],
        ttkNotebook    => [ 'ttk::notebook',    'tnb' ],
        ttkTreeview    => [ 'ttk::treeview',    'ttv' ],
        ttkScrollbar   => [ 'ttk::scrollbar',   'tsb' ],
        ttkCheckbutton => [ 'ttk::checkbutton', 'tcb' ],
        ttkRadiobutton => [ 'ttk::radiobutton', 'trb' ],
        ttkCombobox    => [ 'ttk::combobox',    'tco' ],
        ttkProgressbar => [ 'ttk::progressbar', 'tpb' ],
        ttkScale       => [ 'ttk::scale',       'tsc' ],
        ttkSeparator   => [ 'ttk::separator',   'tsp' ],
        ttkPanedwindow => [ 'ttk::panedwindow', 'tpw' ],
        ttkLabelframe  => [ 'ttk::labelframe',  'tlf' ],
        ttkLabelFrame  => [ 'ttk::labelframe',  'tlf' ],
        ttkMenubutton  => [ 'ttk::menubutton',  'tmb' ],
        ttkSizegrip    => [ 'ttk::sizegrip',    'tsg' ],
        ttkSpinbox     => [ 'ttk::spinbox',     'txp' ],
        TtkButton      => [ 'ttk::button',      'tb'  ],
        TtkLabel       => [ 'ttk::label',       'tlb' ],
        TtkEntry       => [ 'ttk::entry',       'te'  ],
        TtkFrame       => [ 'ttk::frame',       'tf'  ],
        TtkNotebook    => [ 'ttk::notebook',    'tnb' ],
        TtkTreeview    => [ 'ttk::treeview',    'ttv' ],
        TtkScrollbar   => [ 'ttk::scrollbar',   'tsb' ],
        TtkCheckbutton => [ 'ttk::checkbutton', 'tcb' ],
        TtkRadiobutton => [ 'ttk::radiobutton', 'trb' ],
        TtkCombobox    => [ 'ttk::combobox',    'tco' ],
        TtkProgressbar => [ 'ttk::progressbar', 'tpb' ],
        TtkScale       => [ 'ttk::scale',       'tsc' ],
        TtkSeparator   => [ 'ttk::separator',   'tsp' ],
        TtkPanedwindow => [ 'ttk::panedwindow', 'tpw' ],
        TtkLabelframe  => [ 'ttk::labelframe',  'tlf' ],
        TtkLabelFrame  => [ 'ttk::labelframe',  'tlf' ],
        TtkMenubutton  => [ 'ttk::menubutton',  'tmb' ],
        TtkSizegrip    => [ 'ttk::sizegrip',    'tsg' ],
        TtkSpinbox     => [ 'ttk::spinbox',     'txp' ],
    );

    no strict 'refs';
    for my $method (keys %WIDGET_FACTORIES) {
        my ($tcl_cmd, $prefix) = @{ $WIDGET_FACTORIES{$method} };
        *{"Tcl::Tk::MT::Widget::$method"} = sub {
            my ($self, @args) = @_;
            my $interp = $self->{interp};
            my $path   = Tcl::Tk::MT::_next_widget_path($self->{path}, $prefix);
            my @norm   = Tcl::Tk::MT::_prepare_opts($interp, @args);
            Tcl::Tk::MT::Dispatch::marshal_icall($interp, 1, $tcl_cmd, $path, @norm);
            my $w = bless {
                interp => $interp,
                path   => $path,
                parent => $self,
                kind   => $tcl_cmd,
            }, 'Tcl::Tk::MT::Widget';
            return Tcl::Tk::MT::_register_widget($interp, $path, $w);
        };
    }

    # Compiled geometry manager methods
    for my $gm (qw(pack grid place)) {
        *{"Tcl::Tk::MT::Widget::$gm"} = sub {
            my ($self, @args) = @_;
            my @norm = Tcl::Tk::MT::_normalize_opts(@args);
            Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 0, $gm, $self->{path}, @norm);
            return $self;
        };
        my $forget = "${gm}Forget";
        *{"Tcl::Tk::MT::Widget::$forget"} = sub {
            my ($self) = @_;
            Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 0, $gm, 'forget', $self->{path});
            return $self;
        };
        my $cfg = "${gm}Configure";
        *{"Tcl::Tk::MT::Widget::$cfg"} = sub {
            my ($self, @args) = @_;
            my @norm = Tcl::Tk::MT::_normalize_opts(@args);
            Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 0, $gm, 'configure', $self->{path}, @norm);
            return $self;
        };
        my $info = "${gm}Info";
        *{"Tcl::Tk::MT::Widget::$info"} = sub {
            my ($self) = @_;
            return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 1, $gm, 'info', $self->{path});
        };
    }

    # Compiled common widget subcommands
    for my $subcmd (qw(
        insert delete get set index see tag mark add
        entryconfigure entrycget post unpost invoke select deselect
        toggle flash yview xview selection curselection size
        item heading column tab identify bbox state instate
        activate nearest move exists
    )) {
        *{"Tcl::Tk::MT::Widget::$subcmd"} = sub {
            my ($self, @args) = @_;
            return Tcl::Tk::MT::Dispatch::marshal_icall(
                $self->{interp}, wantarray || defined(wantarray),
                $self->{path}, $subcmd, @args
            );
        };
    }
}

sub path   { $_[0]{path} }
sub interp { $_[0]{interp} }
sub parent { $_[0]{parent} }
sub kind   { $_[0]{kind} }

sub widget {
    my ($self, @args) = @_;
    return Tcl::Tk::MT::widget($self->{interp}, @args);
}

sub widget_data {
    my ($self) = @_;
    return Tcl::Tk::MT::widget_data($self);
}

sub Declare {
    my ($self, @args) = @_;
    return Tcl::Tk::MT::Declare($self, @args);
}

sub _populate_menuitems {
    my ($menu, $items) = @_;
    return unless ref($items) eq 'ARRAY';
    for my $spec (@$items) {
        next unless ref($spec) eq 'ARRAY' && @$spec;
        my ($kind, $raw_label, @rest) = @$spec;
        my $lk = lc($kind // 'command');

        if ($lk eq 'separator') {
            $menu->add('separator');
            next;
        }

        my @opts;
        if (defined $raw_label && length $raw_label) {
            my $lbl = $raw_label;
            my $ul;
            if ($lbl =~ s/~(.)/$1/) {
                $ul = $-[0];
            }
            push @opts, ('-label', $lbl);
            push @opts, ('-underline', $ul) if defined $ul;
        }

        if ($lk eq 'cascade') {
            my ($sub_items, $tearoff);
            my @cascade_rest;
            my $i = 0;
            while ($i < @rest) {
                my $k = $rest[$i++];
                my $v = ($i < @rest) ? $rest[$i++] : undef;
                if (defined $k && ($k eq '-menuitems' || $k eq 'menuitems')) {
                    $sub_items = $v;
                }
                elsif (defined $k && ($k eq '-tearoff' || $k eq 'tearoff')) {
                    $tearoff = $v;
                }
                else {
                    push @cascade_rest, ($k, $v);
                }
            }
            my @sub_args;
            push @sub_args, ('-tearoff', $tearoff) if defined $tearoff;
            push @sub_args, ('-menuitems', $sub_items) if defined $sub_items;
            my $submenu = $menu->Menu(@sub_args);
            my @norm = Tcl::Tk::MT::_prepare_opts($menu->{interp}, @opts, '-menu', $submenu, @cascade_rest);
            $menu->add('cascade', @norm);
        }
        else {
            my $tcl_type = ($lk eq 'button') ? 'command' : $lk;
            my @norm = Tcl::Tk::MT::_prepare_opts($menu->{interp}, @opts, @rest);
            $menu->add($tcl_type, @norm);
        }
    }
}

sub Menu {
    my ($self, @args) = @_;
    my $interp = $self->{interp};
    my $path   = Tcl::Tk::MT::_next_widget_path($self->{path}, 'm');

    my $menuitems;
    my @filtered;
    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        if (defined $k && !ref($k) && ($k eq '-menuitems' || $k eq 'menuitems') && $i < @args) {
            $menuitems = $args[$i++];
            next;
        }
        push @filtered, $k;
        push @filtered, $args[$i++] if $i < @args;
    }

    my @norm = Tcl::Tk::MT::_prepare_opts($interp, @filtered);
    Tcl::Tk::MT::Dispatch::marshal_icall($interp, 1, 'menu', $path, @norm);
    my $class = $Tcl::Tk::MT::DROPIN_ACTIVE ? 'Tcl::Tk::Widget::Menu' : 'Tcl::Tk::MT::Widget';
    my $w = bless {
        interp => $interp,
        path   => $path,
        parent => $self,
        kind   => 'menu',
    }, $class;
    Tcl::Tk::MT::_register_widget($interp, $path, $w);
    _populate_menuitems($w, $menuitems) if defined $menuitems;
    return $w;
}

sub Menubutton {
    my ($self, @args) = @_;
    my $interp = $self->{interp};
    my $path   = Tcl::Tk::MT::_next_widget_path($self->{path}, 'mb');

    my ($menuitems, $tearoff);
    my @filtered;
    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        if (defined $k && !ref($k) && ($k eq '-menuitems' || $k eq 'menuitems') && $i < @args) {
            $menuitems = $args[$i++];
            next;
        }
        if (defined $k && !ref($k) && ($k eq '-tearoff' || $k eq 'tearoff') && $i < @args) {
            $tearoff = $args[$i++];
            next;
        }
        push @filtered, $k;
        push @filtered, $args[$i++] if $i < @args;
    }

    my @norm = Tcl::Tk::MT::_prepare_opts($interp, @filtered);
    Tcl::Tk::MT::Dispatch::marshal_icall($interp, 1, 'menubutton', $path, @norm);
    my $w = bless {
        interp => $interp,
        path   => $path,
        parent => $self,
        kind   => 'menubutton',
    }, 'Tcl::Tk::MT::Widget';
    Tcl::Tk::MT::_register_widget($interp, $path, $w);

    if (defined $menuitems || defined $tearoff) {
        my @margs;
        push @margs, ('-tearoff', $tearoff) if defined $tearoff;
        push @margs, ('-menuitems', $menuitems) if defined $menuitems;
        my $menu = $w->Menu(@margs);
        $w->configure('-menu' => $menu);
    }
    return $w;
}

sub Optionmenu {
    my ($self, @args) = @_;
    my $interp = $self->{interp};
    my $path   = Tcl::Tk::MT::_next_widget_path($self->{path}, 'om');

    my ($options, $varref, $tvarref, $cmd);
    my @filtered;
    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        my $v = ($i < @args) ? $args[$i++] : undef;
        my $lk = defined($k) ? $k : '';
        $lk =~ s/\A-//;
        if ($lk eq 'options') {
            $options = $v;
        }
        elsif ($lk eq 'variable') {
            $varref = $v;
        }
        elsif ($lk eq 'textvariable') {
            $tvarref = $v;
        }
        elsif ($lk eq 'command') {
            $cmd = $v;
        }
        else {
            push @filtered, ($k, $v);
        }
    }

    my $fallback_var;
    $varref = \$fallback_var unless defined $varref;
    my $tcl_var = Tcl::Tk::MT::_ensure_tcl_var($interp, $varref);

    my $tcl_tvar;
    if (defined $tvarref) {
        $tcl_tvar = Tcl::Tk::MT::_ensure_tcl_var($interp, $tvarref);
    }

    my @mb_opts = (
        '-indicatoron'  => 1,
        '-relief'       => 'raised',
        '-borderwidth'  => 2,
        '-textvariable' => (defined $tcl_tvar ? $tcl_tvar : $tcl_var),
        @filtered,
    );
    my @norm = Tcl::Tk::MT::_prepare_opts($interp, @mb_opts);
    Tcl::Tk::MT::Dispatch::marshal_icall($interp, 1, 'menubutton', $path, @norm);

    my $w = bless {
        interp   => $interp,
        path     => $path,
        parent   => $self,
        kind     => 'optionmenu',
        _varref  => $varref,
        _tvarref => $tvarref,
    }, 'Tcl::Tk::MT::Widget';
    Tcl::Tk::MT::_register_widget($interp, $path, $w);

    my $menu = $w->Menu('-tearoff' => 0);
    $w->{_menu} = $menu;
    $w->configure('-menu' => $menu);

    if (ref($options) eq 'ARRAY') {
        my $cur_val = $$varref;
        my $matched_label;
        my ($first_label, $first_val);
        for my $item (@$options) {
            my ($label, $val) = (ref($item) eq 'ARRAY') ? ($item->[0], $item->[1]) : ($item, $item);
            $first_label = $label unless defined $first_label;
            $first_val   = $val   unless defined $first_val;
            if (defined $cur_val && defined $val && "$cur_val" eq "$val") {
                $matched_label = $label;
            }
            my $entry_cmd = sub {
                $$tvarref = $label if defined $tvarref;
                if (defined $cmd) {
                    if (ref($cmd) eq 'CODE') {
                        $cmd->($val);
                    }
                    elsif (ref($cmd) eq 'ARRAY' && @$cmd && ref($cmd->[0]) eq 'CODE') {
                        my ($fn, @extra) = @$cmd;
                        $fn->(@extra, $val);
                    }
                }
            };
            $menu->add('radiobutton',
                '-label'    => $label,
                '-value'    => $val,
                '-variable' => $tcl_var,
                '-command'  => $entry_cmd,
            );
        }
        if (defined $tvarref) {
            if (defined $matched_label) {
                $$tvarref = $matched_label;
            }
            elsif (defined $first_label) {
                $$tvarref = $first_label;
                $$varref  = $first_val unless defined $$varref;
            }
        }
        elsif (!defined $$varref && defined $first_val) {
            $$varref = $first_val;
        }
    }

    return $w;
}

sub Scrolled {
    my ($self, $widget_type, @args) = @_;
    my $scrollbars = 'se';
    my @wargs;
    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        if (defined $k && !ref($k) && ($k eq '-scrollbars' || $k eq 'scrollbars') && $i < @args) {
            $scrollbars = $args[$i++];
            next;
        }
        push @wargs, $k;
        push @wargs, $args[$i++] if $i < @args;
    }

    my $frame = $self->Frame();
    my $inner = $frame->$widget_type(@wargs);
    $inner->grid('-row' => 1, '-column' => 1, '-sticky' => 'nsew');
    $frame->gridRowconfigure(1, '-weight' => 1);
    $frame->gridColumnconfigure(1, '-weight' => 1);

    my $sb_spec = lc($scrollbars // '');
    if ($sb_spec =~ /[ew]/) {
        my $ysb = $frame->Scrollbar('-orient' => 'vertical', '-command' => "$inner yview");
        $inner->configure('-yscrollcommand' => "$ysb set");
        my $col = ($sb_spec =~ /w/) ? 0 : 2;
        $ysb->grid('-row' => 1, '-column' => $col, '-sticky' => 'ns');
    }
    if ($sb_spec =~ /[ns]/) {
        my $xsb = $frame->Scrollbar('-orient' => 'horizontal', '-command' => "$inner xview");
        $inner->configure('-xscrollcommand' => "$xsb set");
        my $row = ($sb_spec =~ /n/) ? 0 : 2;
        $xsb->grid('-row' => $row, '-column' => 1, '-sticky' => 'ew');
    }

    return bless {
        interp => $self->{interp},
        path   => $inner->{path},
        parent => $self,
        kind   => $inner->{kind},
        _frame => $frame,
        _inner => $inner,
    }, 'Tcl::Tk::MT::Scrolled';
}

sub icall {
    my ($self, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, defined(wantarray), @args);
}

sub call {
    my ($self, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, defined(wantarray), @args);
}

# Return accelerated Tcl::Tk::MT::Canvas unless TCL_TK_MT_ACCEL=off or -accel => 0
sub Canvas {
    my ($self, @args) = @_;
    my $accel = 1;
    $accel = 0 if defined($ENV{TCL_TK_MT_ACCEL}) && lc($ENV{TCL_TK_MT_ACCEL}) eq 'off';

    # Check for explicit -accel / accel option
    my @filtered;
    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i];
        if (defined($k) && !ref($k) && ($k eq '-accel' || $k eq 'accel') && $i + 1 < @args) {
            $accel = $args[$i + 1] ? 1 : 0;
            $i += 2;
            next;
        }
        push @filtered, $k;
        $i++;
    }

    if ($accel) {
        require Tcl::Tk::MT::Canvas;
        return Tcl::Tk::MT::Canvas->new($self, @filtered);
    }

    # Native Tk canvas fallback
    my $interp = $self->{interp};
    my $path   = Tcl::Tk::MT::_next_widget_path($self->{path}, 'c');
    my @norm   = Tcl::Tk::MT::_prepare_opts($interp, @filtered);
    Tcl::Tk::MT::Dispatch::marshal_icall($interp, 1, 'canvas', $path, @norm);
    my $w = bless {
        interp => $interp,
        path   => $path,
        parent => $self,
        kind   => 'canvas',
    }, 'Tcl::Tk::MT::NativeCanvas';
    return Tcl::Tk::MT::_register_widget($interp, $path, $w);
}

sub Photo {
    my ($self, @args) = @_;
    require Tcl::Tk::MT::Photo;
    return Tcl::Tk::MT::Photo->new($self->{interp}, @args);
}

sub Surface {
    my ($self, @args) = @_;
    require Tcl::Tk::MT::Surface;
    return Tcl::Tk::MT::Surface->new($self, @args);
}

sub configure {
    my ($self, @args) = @_;
    my @rest;
    my $is_top = ($self->{kind} eq 'mainwindow' || $self->{kind} eq 'toplevel');
    if ($is_top) {
        my $i = 0;
        while ($i < @args) {
            my $k = $args[$i++];
            if (defined($k) && !ref($k) && ($k eq '-title' || $k eq 'title') && $i < @args) {
                $self->title($args[$i++]);
                next;
            }
            push @rest, $k;
            push @rest, $args[$i++] if $i < @args;
        }
        return unless @rest;
    }
    else {
        @rest = @args;
    }
    my @norm = Tcl::Tk::MT::_prepare_opts($self->{interp}, @rest);
    return Tcl::Tk::MT::Dispatch::marshal_icall(
        $self->{interp}, defined(wantarray), $self->{path}, 'configure', @norm
    );
}

*config = \&configure;

sub cget {
    my ($self, $opt) = @_;
    my $nopt = Tcl::Tk::MT::_norm_opt($opt);
    if (($self->{kind} eq 'mainwindow' || $self->{kind} eq 'toplevel') && $nopt eq '-title') {
        return $self->title();
    }
    if ($nopt eq '-variable' && exists $self->{_varref}) {
        return $self->{_varref};
    }
    if ($nopt eq '-menu' && exists $self->{_menu}) {
        return $self->{_menu};
    }
    my $val = Tcl::Tk::MT::Dispatch::marshal_icall(
        $self->{interp}, 1, $self->{path}, 'cget', $nopt
    );
    if (($nopt eq '-variable' || $nopt eq '-textvariable') && defined $val && length $val) {
        my $ref = Tcl::Tk::MT::_lookup_tcl_var_ref($self->{interp}, $val);
        return $ref if defined $ref;
    }
    if ($nopt eq '-menu' && defined $val && length $val) {
        my $w = Tcl::Tk::MT::widget_by_path($self->{interp}, $val);
        return $w if defined $w;
    }
    return $val;
}

sub children {
    my ($self, @args) = @_;
    if ($self->{kind} eq 'ttk::treeview' || @args) {
        return Tcl::Tk::MT::Dispatch::marshal_icall(
            $self->{interp}, wantarray || defined(wantarray),
            $self->{path}, 'children', @args
        );
    }
    my @paths = $self->{interp}->icall_list('winfo', 'children', $self->{path});
    my @objs = map { Tcl::Tk::MT::widget($self->{interp}, $_) } @paths;
    return wantarray ? @objs : \@objs;
}

sub bell {
    my ($self, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 0, 'bell', @args);
}

sub destroy {
    my ($self) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 0, 'destroy', $self->{path});
}

sub winfo {
    my ($self, $sub, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall(
        $self->{interp}, 1, 'winfo', $sub, $self->{path}, @args
    );
}

sub focus {
    my ($self, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 0, 'focus', @args, $self->{path});
}

sub raise {
    my ($self, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 0, 'raise', $self->{path}, @args);
}

sub lower {
    my ($self, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 0, 'lower', $self->{path}, @args);
}

sub gridRowconfigure {
    my ($self, $row, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall(
        $self->{interp}, defined(wantarray),
        'grid', 'rowconfigure', $self->{path}, $row, Tcl::Tk::MT::_normalize_opts(@args)
    );
}

sub gridColumnconfigure {
    my ($self, $col, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall(
        $self->{interp}, defined(wantarray),
        'grid', 'columnconfigure', $self->{path}, $col, Tcl::Tk::MT::_normalize_opts(@args)
    );
}

sub bind {
    my ($self, $seq, $cb) = @_;
    my $interp = $self->{interp};
    if (@_ == 1) {
        return $interp->icall('bind', $self->{path});
    }
    if (@_ == 2) {
        return $interp->icall_scalar('bind', $self->{path}, $seq);
    }
    if (ref($cb) eq 'ARRAY') {
        my ($code, @extra) = @$cb;
        my @ev_substs;
        my @bound_args;
        for my $a (@extra) {
            if (blessed($a) && $a->isa('Tcl::Tk::MT::Ev')) {
                for my $field (@$a) {
                    push @ev_substs, '%' . $field;
                }
            }
            else {
                push @bound_args, $a;
            }
        }
        my $cmd_name = '::tkmt_bind_' . (++$WIDGET_SEQ);
        $interp->CreateCommand($cmd_name, sub {
            $code->($self, @bound_args, @_);
        });
        my $script = join(' ', $cmd_name, @ev_substs);
        return $interp->icall('bind', $self->{path}, $seq, $script);
    }
    return $interp->icall('bind', $self->{path}, $seq, $cb);
}

sub after {
    my ($self, $ms, @rest) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 1, 'after', $ms, @rest);
}

sub afterCancel {
    my ($self, $id) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall($self->{interp}, 0, 'after', 'cancel', $id);
}

sub fileevent {
    my ($self, $fh, $mode, $cb) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall(
        $self->{interp}, 0, 'fileevent', $fh, $mode, defined($cb) ? $cb : ''
    );
}

sub update {
    my ($self, $mode) = @_;
    Tcl::Tk::MT::Dispatch::pump_once($self->{interp});
    if (defined $mode && $mode eq 'idletasks') {
        $self->{interp}->icall('update', 'idletasks');
    }
    else {
        $self->{interp}->icall('update');
    }
    Tcl::Tk::MT::Dispatch::pump_once($self->{interp});
    return;
}

sub waitVariable {
    my ($self, $varref) = @_;
    my $tcl_var = Tcl::Tk::MT::_ensure_tcl_var($self->{interp}, $varref);
    $self->{interp}->icall('tkwait', 'variable', $tcl_var);
    return;
}

sub wm {
    my ($self, $sub, @args) = @_;
    return Tcl::Tk::MT::Dispatch::marshal_icall(
        $self->{interp}, defined(wantarray), 'wm', $sub, $self->{path}, @args
    );
}

# Window manager convenience methods
for my $wm_cmd (qw(
    title geometry withdraw deiconify iconify protocol
    resizable minsize maxsize attributes
)) {
    no strict 'refs';
    *{"Tcl::Tk::MT::Widget::$wm_cmd"} = sub {
        my ($self, @args) = @_;
        return Tcl::Tk::MT::Dispatch::marshal_icall(
            $self->{interp}, defined(wantarray), 'wm', $wm_cmd, $self->{path}, @args
        );
    };
}

sub MainLoop {
    my ($self) = @_;
    return Tcl::Tk::MT::MainLoop($self->{interp});
}

sub DoOneEvent {
    my ($self, $flags) = @_;
    $flags = 0 unless defined $flags;
    Tcl::Tk::MT::Dispatch::pump_once($self->{interp});
    return $self->{interp}->DoOneEvent($flags);
}

our $AUTOLOAD;
sub AUTOLOAD {
    my ($self, @args) = @_;
    my $method = $AUTOLOAD;
    $method =~ s/\A.*:://;
    return if $method eq 'DESTROY';

    # Strip optional leading underscore (_insertEnd -> insertEnd) and split camelCase
    $method =~ s/\A_//;
    my @words = map { lc } split /(?=[A-Z])/, $method;
    return Tcl::Tk::MT::Dispatch::marshal_icall(
        $self->{interp}, wantarray || defined(wantarray),
        $self->{path}, @words, @args
    );
}

# =============================================================================
# Tcl::Tk::MT::Scrolled - Composite widget with attached scrollbars
# =============================================================================
package Tcl::Tk::MT::Scrolled;

use strict;
use warnings;
our @ISA = ('Tcl::Tk::MT::Widget');

for my $gm (qw(pack grid place packForget gridForget placeForget packConfigure gridConfigure placeConfigure packInfo gridInfo placeInfo destroy)) {
    no strict 'refs';
    *{"Tcl::Tk::MT::Scrolled::$gm"} = sub {
        my ($self, @args) = @_;
        my $res = $self->{_frame}->$gm(@args);
        return ($gm eq 'pack' || $gm eq 'grid' || $gm eq 'place') ? $self : $res;
    };
}

sub Subwidget {
    my ($self, $name) = @_;
    return $self->{_inner};
}

# =============================================================================
# Tcl::Tk::MT::MainWindow - Root '.' window
# =============================================================================
package Tcl::Tk::MT::MainWindow;

use strict;
use warnings;
our @ISA = ('Tcl::Tk::MT::Widget');

sub new {
    my ($class, @args) = @_;
    my $interp = Tcl::MT->new_tk();
    Tcl::Tk::MT::Dispatch::install_idle_hook($interp);
    $Tcl::Tk::MT::DEFAULT_INTERP = $interp;

    my $self = $class->_wrap_interp($interp);
    if (@args) {
        $self->configure(@args);
    }
    return $self;
}

sub _wrap_interp {
    my ($class, $interp) = @_;
    my $self = bless {
        interp => $interp,
        path   => '.',
        parent => undef,
        kind   => 'mainwindow',
    }, $class;
    return Tcl::Tk::MT::_register_widget($interp, '.', $self);
}

# =============================================================================
# MainWindow - Global package alias so `MainWindow->new(...)` works even when
# Tcl::Tk::MT is loaded at runtime (`require Tcl::Tk::MT`) or without import.
# =============================================================================
{
    package MainWindow;
    our @ISA;
    push @ISA, 'Tcl::Tk::MT::MainWindow' unless __PACKAGE__->can('new');
}

# =============================================================================
# Tcl::Tk::MT::NativeCanvas - Thin wrapper for fallback native Tk canvas
# =============================================================================
package Tcl::Tk::MT::NativeCanvas;

use strict;
use warnings;
our @ISA = ('Tcl::Tk::MT::Widget');

BEGIN {
    no strict 'refs';
    for my $type (qw(Line Rectangle Oval Arc Polygon Text Image Window)) {
        my $lc = lc($type);
        my $fn = sub {
            my ($self, @args) = @_;
            return $self->{interp}->icall_scalar($self->{path}, 'create', $lc, @args);
        };
        *{"Tcl::Tk::MT::NativeCanvas::create$type"}  = $fn;
        *{"Tcl::Tk::MT::NativeCanvas::_create$type"} = $fn;
    }
    for my $m (qw(
        create coords itemconfigure itemcget move scale delete raise lower
        find addtag dtag gettags bind bbox xview yview postscript
    )) {
        *{"Tcl::Tk::MT::NativeCanvas::$m"} = sub {
            my ($self, @args) = @_;
            return $self->{interp}->icall($self->{path}, $m, @args);
        };
    }
}

sub is_accelerated { 0 }
sub backend_name   { 'off' }

1;

__END__

=head1 NAME

Tcl::Tk::MT - Tcl/Tk interface with optional GPU canvas and perl5-mt integration

=head1 SYNOPSIS

    use Tcl::Tk::MT;

    my $mw = MainWindow->new(-title => 'Tcl::Tk::MT');
    my $c  = $mw->Canvas(-width => 800, -height => 600)->pack;
    $c->createRectangle(10, 10, 200, 120, -fill => '#2266cc');
    MainLoop;

Or run an existing C<Tcl::Tk> script through the compatibility shim:

    perl -MTcl::Tk::MT=:dropin existing_script.pl

=head1 DESCRIPTION

C<Tcl::Tk::MT> implements a compile-time-dispatched widget hierarchy on top of
L<Tcl::MT>, an optional retained 2D L<Tcl::Tk::MT::Canvas> backed by Metal,
Vulkan, or software rendering, and cooperative C<MainLoop> integration for
C<perl5-mt> fibers and channels via L<Tcl::Tk::MT::Dispatch>.

=head1 EXPORTS

Default (C<@EXPORT>): C<MainWindow>, C<MainLoop>, C<Exists>, C<Ev>, C<tkinit>, C<new_interp>.

Optional (C<@EXPORT_OK>): C<DoOneEvent>, C<update>, C<after>, C<afterCancel>,
C<fileevent>, C<waitVariable>, C<mainwindow>, C<interp>, C<widget_by_path>.

Import tags: C<:default>, C<:all>, C<:dropin> (installs L<Tcl::Tk::MT::Shim>).

=head1 WIDGETS & CANVAS ACCELERATION

C<Tcl::Tk::MT::Widget> compiles factory methods at load time for standard Tk
widgets (C<Button>, C<Label>, C<Entry>, C<Frame>, C<Scrollbar>, C<Menu>,
C<Toplevel>, C<Text>, C<Checkbutton>, C<Radiobutton>, C<Listbox>, C<Scale>,
C<Spinbox>, C<Labelframe>, C<Panedwindow>, C<Message>, C<Menubutton>) and
ttk widgets (C<Notebook>, C<Treeview>, C<ttkButton>, C<ttkLabel>, C<ttkEntry>,
C<ttkFrame>, C<ttkNotebook>, C<ttkTreeview>, C<ttkScrollbar>, C<ttkCheckbutton>,
C<ttkRadiobutton>, C<ttkCombobox>, C<ttkProgressbar>, C<ttkScale>,
C<ttkSeparator>, C<ttkPanedwindow>, C<ttkLabelframe>, C<ttkMenubutton>,
C<ttkSizegrip>, C<ttkSpinbox>).

C<< $widget->Canvas(...) >> returns an accelerated L<Tcl::Tk::MT::Canvas> by
default; pass C<< -accel => 0 >> or set C<TCL_TK_MT_ACCEL=off> to fall back
to C<Tcl::Tk::MT::NativeCanvas>.

C<< $widget->Photo(...) >> constructs a L<Tcl::Tk::MT::Photo> bound to the
widget's interpreter.

C<< $widget->Surface(...) >> constructs a L<Tcl::Tk::MT::Surface> host frame
exposing the platform native window handle for external renderers.

=head1 LIMITATIONS

Tk widgets remain bound to the OS thread that created the interpreter; worker
threads must marshal updates through L<Tcl::MT> or L<Tcl::Tk::MT::Dispatch>.
The accelerated canvas does not implement every native Tk canvas option (such
as bitmap stipples or vector PostScript); use C<< -accel => 0 >> or
C<TCL_TK_MT_ACCEL=off> when exact native Tk canvas behavior is required.

=head1 ACKNOWLEDGMENTS

This module builds on the conventions and API established by Vadim Konovalov,
Christopher Chavez, and the contributors to C<Tcl>, C<Tcl::Tk>, C<Tcl::pTk>,
Tcl/Tk, and Perl 5.

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as Perl 5 itself.

=cut
