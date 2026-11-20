#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# Enable drop-in shim before loading Tcl / Tcl::Tk / Tcl::pTk
use Tcl::Tk::MT qw(:dropin);
use Tcl;
use Tcl::Tk qw(:perlTk);
use Tcl::pTk;

ok($INC{'Tcl.pm'},     'Tcl.pm populated by :dropin shim');
ok($INC{'Tcl/Tk.pm'},  'Tcl/Tk.pm populated by :dropin shim');
ok($INC{'Tcl/pTk.pm'}, 'Tcl/pTk.pm populated by :dropin shim');
ok(defined $Tcl::VERSION && defined $Tcl::Tk::VERSION && defined $Tcl::pTk::VERSION,
   'Tcl, Tcl::Tk, and Tcl::pTk VERSION variables defined');

# Interpreter-first construction (Tcl::Tk->new + mainwindow + Eval + pkg_require)
my $int = eval { Tcl::Tk->new() };
if ($@ || !$int) {
    plan skip_all => "No Tk display available: $@";
}

my $mw = $int->mainwindow;
$mw->withdraw;

isa_ok($mw, 'Tcl::Tk::Widget', 'MainWindow');
ok(Exists($mw), 'Exists($mw) is true');
ok(Tcl::Tk::Exists($mw), 'Tcl::Tk::Exists($mw) is true');
is("$mw", '.', 'widget stringifies to Tcl path');
is($mw->path, '.', 'path accessor returns "."');

my $tcl_ver = $int->Eval('info tclversion');
ok(defined $tcl_ver && length $tcl_ver, "int->Eval works (Tcl $tcl_ver)");
ok($mw->interp->pkg_require('Tk'), 'interp->pkg_require("Tk") succeeds');
ok(!$mw->interp->pkg_require('NonExistentPackageXYZ_999'), 'pkg_require returns false for missing package');

# MainWindow configure/cget -title, config alias, bell
$mw->configure(-title => 'Upstream Compat');
is($mw->cget('-title'), 'Upstream Compat', 'MainWindow configure/cget -title');
$mw->config(-title => 'Compat Alias');
is($mw->cget('-title'), 'Compat Alias', 'config alias updates title');
eval { $mw->bell };
is($@, '', 'bell executes without error');

# Capitalized Ttk* and LabelFrame constructors
my $lf = $mw->LabelFrame(-text => 'Section')->pack;
is($lf->cget('-text'), 'Section', 'LabelFrame constructor and cget');

for my $ttk_cls (qw(
    TtkButton TtkLabel TtkEntry TtkFrame TtkLabelframe TtkNotebook
    TtkScrollbar TtkCombobox TtkProgressbar TtkScale TtkSeparator
    TtkSizegrip TtkTreeview TtkPanedwindow TtkSpinbox
    TtkCheckbutton TtkRadiobutton
)) {
    my $w = eval { $mw->$ttk_cls() };
    ok(defined($w) && !$@, "Ttk constructor: $ttk_cls");
    $w->destroy if defined $w;
}

# Children returns widget objects
my @kids = $mw->children;
ok(@kids >= 1 && $kids[0]->isa('Tcl::Tk::Widget'), 'children() returns widget objects');
is($kids[0]->cget('-text'), 'Section', 'children()[0] matches created LabelFrame');

# Menubutton and Menu with -tearoff and -menuitems
my $mb = $mw->Menubutton(
    -text      => 'File',
    -underline => 0,
    -tearoff   => 0,
    -menuitems => [
        [ Button    => '~Open', -accelerator => 'Control+o' ],
        [ Cascade   => '~Sub', -tearoff => 0, -menuitems => [
            [ Button => '~Item 1' ],
        ] ],
        [ Separator => '' ],
        [ Button    => '~Quit', -command => sub {} ],
    ],
)->pack;
ok(Exists($mb), 'Menubutton with -tearoff and -menuitems created');

my $menu = $mw->Menu(-tearoff => 0, -menuitems => [
    [ Button => '~First' ],
    [ Separator => '' ],
    [ Button => '~Last' ],
]);
is(ref($menu), 'Tcl::Tk::Widget::Menu', 'Menu blessed as Tcl::Tk::Widget::Menu under :dropin');
is($menu->entrycget(0, '-label'), 'First', 'Menu item label parsed without ~');
is($menu->entrycget(0, '-underline'), 0, 'Menu item underline parsed from ~');

# Optionmenu with scalar -variable, -textvariable, and pair options
my $opt_val = 2;
my $om = $mw->Optionmenu(-variable => \$opt_val, -options => [0..5])->pack;
ok(Exists($om), 'Optionmenu created');
is($om->cget('-variable'), \$opt_val, 'Optionmenu cget(-variable) returns original scalar ref');
is(${ $om->cget('-variable') }, 2, 'Optionmenu dereferenced -variable matches initial value');
my $om_menu = $om->cget('-menu');
is(ref($om_menu), 'Tcl::Tk::Widget::Menu', 'Optionmenu cget(-menu) returns Tcl::Tk::Widget::Menu');
is($om_menu->index('last'), 5, 'Optionmenu menu index("last") matches option count');
is($om_menu->entrycget('last', '-label'), '5', 'Optionmenu last label matches');

my $pair_val = 3;
my $pair_txt = '';
my $om2 = $mw->Optionmenu(
    -variable     => \$pair_val,
    -textvariable => \$pair_txt,
    -options      => [ map { [ "Label $_" => $_ ] } (0..5) ],
)->pack;
is($pair_txt, 'Label 3', 'Optionmenu pair options initialize -textvariable');

# Bidirectional linked -textvariable on Entry
my $entry_var = 'initial';
my $entry = $mw->Entry(-textvariable => \$entry_var)->pack;
is($entry->get, 'initial', 'Entry reflects initial linked -textvariable');
$entry_var = 'from_perl';
is($entry->get, 'from_perl', 'Perl write to tied scalar updates Entry');
$entry->delete(0, 'end');
$entry->insert(0, 'from_tk');
is($entry_var, 'from_tk', 'Tk mutation updates tied Perl scalar');

# Scrolled Text + underscore/camelCase AUTOLOAD methods + windowCreate
my $st = $mw->Scrolled('Text', -scrollbars => 'osoe')->pack;
$st->_insert('end', "line 1\n");
$st->_insertEnd("line 2\n");
$st->_seeEnd;
$st->_tagAddSel('1.0', '1.4');
$st->windowCreate('end', -window => $mw->Button(-text => 'InText'));
like($st->get('1.0', 'end'), qr/line 1\nline 2/, 'Scrolled Text _insert/_insertEnd/_seeEnd/_tagAddSel/windowCreate');

# Canvas create() and _createRectangle()
my $c = $mw->Canvas(-width => 200, -height => 120, -headless => 1)->pack;
my $rid = $c->_createRectangle(10, 10, 80, 60, -outline => 'black', -fill => 'red');
my $tid = $c->create('text', 20, 20, -text => 'canvas text');
ok($rid > 0 && $tid > 0, 'Canvas _createRectangle and create("text", ...) work');
$c->lower($rid);
$c->raise($tid);
pass('Canvas raise/lower work');

# Geometry manager: grid sibling, relative span '-', gridInfo, gridForget
my $gframe = $mw->Frame()->pack;
my $gb1 = $gframe->Button(-text => 'G1');
my $gb2 = $gframe->Button(-text => 'G2');
eval { $gb1->grid($gb2) };
is($@, '', 'grid with sibling widget succeeds');
$gb1->gridForget;
$gb2->gridForget;

my $gspan = $gframe->Button(-text => 'Span');
$gspan->grid('-');
my %ginfo = $gspan->gridInfo;
is($ginfo{-columnspan}, 2, 'grid("-") sets -columnspan => 2');
$gspan->destroy;
$gb1->destroy;
$gb2->destroy;
$gframe->destroy;

# widget(), widget_data(), Declare()
my $wrapped = $int->widget($lf->path, 'labelframe');
is($wrapped->path, $lf->path, 'int->widget wraps/retrieves widget by path');
$lf->widget_data->{custom_tag} = 42;
is($lf->widget_data->{custom_tag}, 42, 'widget_data stores per-widget metadata');

$mw->Declare('CustomFrame', 'frame', -prefix => 'cf');
my $cf = $mw->CustomFrame(-width => 20, -height => 20);
ok(Exists($cf), 'Declare registers custom widget factory');
like($cf->path, qr/\.cf\d+\z/, 'Declare honors -prefix');

# Unicode + embedded NUL round-trip
my $ut = $mw->Text();
my $sample = "ascii\nNUL(\0) control(\a\r)\n[\x{2030} \0]\n"
           . join('', map chr, 0 .. 255) . "\n"
           . join('', map chr, 0 .. 300) . "\n";
$ut->insert('end', $sample);
$int->Eval("$ut insert end \"\\0\\1\\2\\n\"");
is($ut->get('1.0', 'end'), $sample . "\0\1\2\n\n", 'Unicode, Latin-1, and embedded NUL round-trip');

# TCL_TK_MT_AUTO_EXIT_MS exits MainLoop cleanly
{
    local $ENV{TCL_TK_MT_AUTO_EXIT_MS} = 50;
    $int->MainLoop;
    pass('TCL_TK_MT_AUTO_EXIT_MS cleanly terminated MainLoop');
}

done_testing();
