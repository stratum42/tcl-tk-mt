package Tcl::Tk::MT::Canvas;

use strict;
use warnings;
use Scalar::Util qw(blessed looks_like_number);

use Tcl::Tk::MT ();
use Tcl::Tk::MT::Gfx ();
use Tcl::Tk::MT::Dispatch ();

our $VERSION = '0.01';
our @ISA     = ('Tcl::Tk::MT::Widget');

my %SHAPE_MAP = (
    rect         => 0,
    rectangle    => 0,
    rounded_rect => 1,
    oval         => 2,
    circle       => 2,
    arc          => 3,
    quad_tex     => 4,
);

sub new {
    my ($class, $parent, @args) = @_;

    my %opts = (
        width        => 300,
        height       => 200,
        background   => '#ffffff',
        scrollregion => undef,
        backend      => undef,
        headless     => 0,
    );
    my @tk_opts;

    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        my $v = ($i < @args) ? $args[$i++] : undef;
        my $lk = defined($k) ? $k : '';
        $lk =~ s/\A-//;
        if ($lk eq 'width' || $lk eq 'height' || $lk eq 'backend' || $lk eq 'headless' || $lk eq 'scrollregion') {
            $opts{$lk} = $v;
        }
        elsif ($lk eq 'bg' || $lk eq 'background') {
            $opts{background} = $v;
        }
        else {
            push @tk_opts, (Tcl::Tk::MT::_norm_opt($k), $v);
        }
    }

    Tcl::Tk::MT::Gfx::init();

    my $w = int($opts{width}  || 300);
    my $h = int($opts{height} || 200);
    $w = 1 if $w < 1;
    $h = 1 if $h < 1;

    my ($interp, $path, $tk_surf);
    if (defined $parent && blessed($parent) && $parent->can('interp')) {
        $interp  = $parent->interp;
        $path    = Tcl::Tk::MT::_next_widget_path($parent->path, 'c');
        $tk_surf = $interp->create_surface($path, $w, $h);
        if (@tk_opts) {
            eval { $interp->icall($path, 'configure', @tk_opts) };
        }
    }

    my $gfx_surf;
    my $scale = 1.0;
    if (defined $tk_surf && !$opts{headless}) {
        my $ninfo = eval { $tk_surf->native_info() };
        $scale = ($ninfo && $ninfo->{scale} && $ninfo->{scale} > 0) ? $ninfo->{scale} : 1.0;
        $gfx_surf = eval {
            Tcl::Tk::MT::Gfx::create_surface($w, $h, $opts{backend}, $scale, 0, $tk_surf->ptr());
        };
    }
    if (!$gfx_surf) {
        $gfx_surf = Tcl::Tk::MT::Gfx::create_surface($w, $h, $opts{backend}, $scale, 1, 0);
    }

    my $scene = Tcl::Tk::MT::Gfx::create_scene($w, $h);
    my $bg_rgba = Tcl::Tk::MT::Gfx::parse_color($opts{background});
    $scene->set_clear_color($bg_rgba, 1);

    my $self = bless {
        interp        => $interp,
        path          => $path,
        parent        => $parent,
        kind          => 'tkmt_canvas',
        tk_surface    => $tk_surf,
        gfx_surface   => $gfx_surf,
        scene         => $scene,
        width         => $w,
        height        => $h,
        background    => $opts{background},
        scrollregion  => $opts{scrollregion},
        pan_x         => 0.0,
        pan_y         => 0.0,
        zoom_x        => 1.0,
        zoom_y        => 1.0,
        item_opts     => {},   # $id => { -fill => ..., -text => ..., ... }
        item_photos   => {},   # $id => $photo_obj (keep ref alive)
        item_windows  => {},   # $id => { path => ..., x => ..., y => ..., w => ..., h => ... }
        item_bindings => {},   # $seq => [ [ $tag_or_id, $cb ], ... ]
        dirty         => 1,
    }, $class;

    Tcl::Tk::MT::_register_widget($interp, $path, $self) if defined $interp && defined $path;
    return $self;
}

sub is_accelerated { 1 }
sub scene          { $_[0]{scene} }
sub surface        { $_[0]{gfx_surface} }
sub tk_surface     { $_[0]{tk_surface} }
sub backend_name   { $_[0]{gfx_surface}->backend_name() }
sub stats          { $_[0]{scene}->stats() }

sub _request_redraw {
    my ($self) = @_;
    $self->{dirty} = 1;
    if (defined $self->{tk_surface} && $self->{scene}->batch_depth() == 0) {
        $self->{tk_surface}->request_redraw();
    }
}

sub render {
    my ($self) = @_;
    my $rc = $self->{scene}->render($self->{gfx_surface});
    $self->{dirty} = 0;
    return $rc;
}

sub readback_rgba {
    my ($self) = @_;
    $self->render() if $self->{dirty};
    return $self->{gfx_surface}->readback_rgba();
}

sub readback_sha256 {
    my ($self) = @_;
    $self->render() if $self->{dirty};
    return $self->{gfx_surface}->readback_sha256();
}

# Split leading numeric coordinates (or leading arrayref) from trailing -key => val options.
sub _split_coords_opts {
    my (@args) = @_;
    my @coords;
    if (@args && ref($args[0]) eq 'ARRAY') {
        @coords = @{ shift @args };
    }
    else {
        while (@args && defined($args[0]) && !ref($args[0]) && looks_like_number($args[0])) {
            push @coords, shift @args;
        }
    }
    my %opts;
    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        my $v = ($i < @args) ? $args[$i++] : undef;
        next unless defined $k;
        $k = "-$k" unless substr($k, 0, 1) eq '-';
        $opts{$k} = $v;
    }
    return (\@coords, \%opts);
}

sub _apply_item_opts {
    my ($self, $id, $type, $opts) = @_;
    my $scene = $self->{scene};
    my $store = ($self->{item_opts}{$id} ||= {});

    # Default Tk colors on creation
    if ($type eq 'line' && !exists $store->{'-fill'} && !exists $opts->{'-fill'}) {
        $opts->{'-fill'} = 'black';
    }
    elsif (($type eq 'rectangle' || $type eq 'oval' || $type eq 'arc')
           && !exists $store->{'-outline'} && !exists $opts->{'-outline'})
    {
        $opts->{'-outline'} = 'black';
    }
    elsif ($type eq 'polygon' && !exists $store->{'-fill'} && !exists $opts->{'-fill'}) {
        $opts->{'-fill'} = 'black';
    }
    elsif ($type eq 'text' && !exists $store->{'-fill'} && !exists $opts->{'-fill'}) {
        $opts->{'-fill'} = 'black';
    }

    if (exists $opts->{'-fill'}) {
        $store->{'-fill'} = $opts->{'-fill'};
        $scene->set_fill($id, Tcl::Tk::MT::Gfx::parse_color($opts->{'-fill'}));
    }
    if (exists $opts->{'-outline'}) {
        $store->{'-outline'} = $opts->{'-outline'};
        $scene->set_outline($id, Tcl::Tk::MT::Gfx::parse_color($opts->{'-outline'}));
    }
    if (exists $opts->{'-width'}) {
        $store->{'-width'} = $opts->{'-width'};
        $scene->set_width($id, $opts->{'-width'} + 0);
    }
    if (exists $opts->{'-radius'} || exists $opts->{'-cornerradius'}) {
        my $r = exists $opts->{'-radius'} ? $opts->{'-radius'} : $opts->{'-cornerradius'};
        $store->{'-radius'} = $r;
        $scene->set_corner_radius($id, $r + 0);
    }
    if (exists $opts->{'-start'} || exists $opts->{'-extent'} || exists $opts->{'-style'}) {
        my $start  = exists $opts->{'-start'}  ? $opts->{'-start'}  : ($store->{'-start'}  // 0.0);
        my $extent = exists $opts->{'-extent'} ? $opts->{'-extent'} : ($store->{'-extent'} // 90.0);
        my $style  = exists $opts->{'-style'}  ? $opts->{'-style'}  : ($store->{'-style'}  // 'pieslice');
        $store->{'-start'}  = $start;
        $store->{'-extent'} = $extent;
        $store->{'-style'}  = $style;
        $scene->set_arc_angles($id, $start + 0, $extent + 0, $style);
    }
    if (exists $opts->{'-capstyle'} || exists $opts->{'-joinstyle'}
        || exists $opts->{'-dash'} || exists $opts->{'-dashoffset'})
    {
        my $cap    = exists $opts->{'-capstyle'}   ? $opts->{'-capstyle'}   : ($store->{'-capstyle'}   // 'butt');
        my $join   = exists $opts->{'-joinstyle'}  ? $opts->{'-joinstyle'}  : ($store->{'-joinstyle'}  // 'miter');
        my $dash   = exists $opts->{'-dash'}       ? $opts->{'-dash'}       : $store->{'-dash'};
        my $offset = exists $opts->{'-dashoffset'} ? $opts->{'-dashoffset'} : ($store->{'-dashoffset'} // 0);
        $store->{'-capstyle'}   = $cap;
        $store->{'-joinstyle'}  = $join;
        $store->{'-dash'}       = $dash;
        $store->{'-dashoffset'} = $offset;
        my $dash_ref = ref($dash) eq 'ARRAY' ? $dash : (defined($dash) && length($dash) ? [ split /\s+/, $dash ] : undef);
        $scene->set_line_style($id, $cap, $join, $dash_ref, $offset + 0);
    }
    if (exists $opts->{'-state'}) {
        $store->{'-state'} = $opts->{'-state'};
        $scene->set_state($id, $opts->{'-state'});
    }
    if (exists $opts->{'-anchor'}) {
        $store->{'-anchor'} = $opts->{'-anchor'};
        $scene->set_anchor($id, $opts->{'-anchor'});
    }
    if (exists $opts->{'-text'} || exists $opts->{'-font'}) {
        my $text = exists $opts->{'-text'} ? $opts->{'-text'} : ($store->{'-text'} // '');
        my $font = exists $opts->{'-font'} ? $opts->{'-font'} : $store->{'-font'};
        $store->{'-text'} = $text;
        $store->{'-font'} = $font if exists $opts->{'-font'};
        my ($family, $size) = _parse_font($font);
        $scene->set_text($id, "$text", $family, $size);
    }
    if (exists $opts->{'-image'}) {
        my $img = $opts->{'-image'};
        $store->{'-image'} = $img;
        if (blessed($img) && $img->can('ensure_texture')) {
            my $tex_id = $img->ensure_texture($self->{gfx_surface});
            $scene->set_image($id, $tex_id, $img->width, $img->height);
            $self->{item_photos}{$id} = $img;
        }
        elsif (defined $img && looks_like_number($img)) {
            $scene->set_image($id, int($img), $opts->{'-width'} || 0, $opts->{'-height'} || 0);
        }
    }
    if (exists $opts->{'-window'}) {
        my $win  = $opts->{'-window'};
        my $wpath = (blessed($win) && $win->can('path')) ? $win->path : "$win";
        my $ww   = $opts->{'-width'}  || 0;
        my $wh   = $opts->{'-height'} || 0;
        $store->{'-window'} = $win;
        $scene->set_window($id, $wpath, $ww, $wh);
        my $coords = $scene->get_coords($id);
        my ($x, $y) = ($coords && @$coords >= 2) ? ($coords->[0], $coords->[1]) : (0, 0);
        $self->{item_windows}{$id} = { path => $wpath, x => $x, y => $y, w => $ww, h => $wh };
        if (defined $self->{tk_surface}) {
            $self->{tk_surface}->place_child($wpath, int($x), int($y), int($ww), int($wh), 1);
        }
    }
    if (exists $opts->{'-tags'}) {
        my $tags = $opts->{'-tags'};
        $store->{'-tags'} = $tags;
        my @list = ref($tags) eq 'ARRAY' ? @$tags : (defined($tags) ? split(/\s+/, $tags) : ());
        for my $t (@list) {
            $scene->add_tag($id, $t) if length $t;
        }
    }
}

sub _parse_font {
    my ($font) = @_;
    return (undef, 12) unless defined $font;
    if (ref($font) eq 'ARRAY') {
        return ($font->[0], ($font->[1] && looks_like_number($font->[1])) ? abs($font->[1]) : 12);
    }
    if ($font =~ /\A(\S+)\s+(-?\d+(?:\.\d+)?)/) {
        return ($1, abs($2));
    }
    return ($font, 12);
}

# Standard Tk Canvas item constructors
sub createLine {
    my ($self, @args) = @_;
    my ($coords, $opts) = _split_coords_opts(@args);
    my $id = $self->{scene}->create_item('line', $coords);
    $self->_apply_item_opts($id, 'line', $opts);
    $self->_request_redraw();
    return $id;
}

sub createRectangle {
    my ($self, @args) = @_;
    my ($coords, $opts) = _split_coords_opts(@args);
    my $id = $self->{scene}->create_item('rectangle', $coords);
    $self->_apply_item_opts($id, 'rectangle', $opts);
    $self->_request_redraw();
    return $id;
}

sub createOval {
    my ($self, @args) = @_;
    my ($coords, $opts) = _split_coords_opts(@args);
    my $id = $self->{scene}->create_item('oval', $coords);
    $self->_apply_item_opts($id, 'oval', $opts);
    $self->_request_redraw();
    return $id;
}

sub createArc {
    my ($self, @args) = @_;
    my ($coords, $opts) = _split_coords_opts(@args);
    my $id = $self->{scene}->create_item('arc', $coords);
    $self->_apply_item_opts($id, 'arc', $opts);
    $self->_request_redraw();
    return $id;
}

sub createPolygon {
    my ($self, @args) = @_;
    my ($coords, $opts) = _split_coords_opts(@args);
    my $id = $self->{scene}->create_item('polygon', $coords);
    $self->_apply_item_opts($id, 'polygon', $opts);
    $self->_request_redraw();
    return $id;
}

sub createText {
    my ($self, @args) = @_;
    my ($coords, $opts) = _split_coords_opts(@args);
    my $id = $self->{scene}->create_item('text', $coords);
    $self->_apply_item_opts($id, 'text', $opts);
    $self->_request_redraw();
    return $id;
}

sub createImage {
    my ($self, @args) = @_;
    my ($coords, $opts) = _split_coords_opts(@args);
    my $id = $self->{scene}->create_item('image', $coords);
    $self->_apply_item_opts($id, 'image', $opts);
    $self->_request_redraw();
    return $id;
}

sub createWindow {
    my ($self, @args) = @_;
    my ($coords, $opts) = _split_coords_opts(@args);
    my $id = $self->{scene}->create_item('window', $coords);
    $self->_apply_item_opts($id, 'window', $opts);
    $self->_request_redraw();
    return $id;
}

my %CREATE_DISPATCH = (
    line      => \&createLine,
    rectangle => \&createRectangle,
    rect      => \&createRectangle,
    oval      => \&createOval,
    arc       => \&createArc,
    polygon   => \&createPolygon,
    text      => \&createText,
    image     => \&createImage,
    window    => \&createWindow,
);

sub create {
    my ($self, $type, @args) = @_;
    my $fn = $CREATE_DISPATCH{ lc($type // '') }
        or die "Canvas::create: unsupported item type '$type'";
    return $fn->($self, @args);
}

{
    no strict 'refs';
    for my $type (qw(Line Rectangle Oval Arc Polygon Text Image Window)) {
        *{"Tcl::Tk::MT::Canvas::_create$type"} = \&{"Tcl::Tk::MT::Canvas::create$type"};
    }
}

# Item manipulation
sub coords {
    my ($self, $id, @rest) = @_;
    if (!@rest) {
        my $c = $self->{scene}->get_coords($id);
        return wantarray ? ($c ? @$c : ()) : $c;
    }
    my $aref = (@rest == 1 && ref($rest[0]) eq 'ARRAY') ? $rest[0] : \@rest;
    $self->{scene}->update_coords_packed($id, $aref);
    if (my $win = $self->{item_windows}{$id}) {
        $win->{x} = $aref->[0] if @$aref >= 1;
        $win->{y} = $aref->[1] if @$aref >= 2;
        if (defined $self->{tk_surface}) {
            $self->{tk_surface}->place_child($win->{path}, int($win->{x}), int($win->{y}), int($win->{w}), int($win->{h}), 1);
        }
    }
    $self->_request_redraw();
    return;
}

sub itemconfigure {
    my ($self, $tag_or_id, @args) = @_;
    my $ids = $self->{scene}->find_withtag($tag_or_id);
    return unless $ids && @$ids;
    if (!@args) {
        return $self->{item_opts}{$ids->[0]} || {};
    }
    my %opts;
    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        my $v = ($i < @args) ? $args[$i++] : undef;
        $k = "-$k" unless substr($k, 0, 1) eq '-';
        $opts{$k} = $v;
    }
    for my $id (@$ids) {
        $self->_apply_item_opts($id, '', \%opts);
    }
    $self->_request_redraw();
    return;
}

sub itemcget {
    my ($self, $tag_or_id, $opt) = @_;
    $opt = "-$opt" unless substr($opt, 0, 1) eq '-';
    my $ids = $self->{scene}->find_withtag($tag_or_id);
    return undef unless $ids && @$ids;
    my $store = $self->{item_opts}{$ids->[0]};
    return $store ? $store->{$opt} : undef;
}

sub move {
    my ($self, $tag_or_id, $dx, $dy) = @_;
    $self->{scene}->move($tag_or_id, $dx + 0, $dy + 0);
    if (keys %{ $self->{item_windows} }) {
        my $ids = $self->{scene}->find_withtag($tag_or_id);
        for my $id (@{ $ids || [] }) {
            if (my $win = $self->{item_windows}{$id}) {
                $win->{x} += $dx;
                $win->{y} += $dy;
                if (defined $self->{tk_surface}) {
                    $self->{tk_surface}->place_child($win->{path}, int($win->{x}), int($win->{y}), int($win->{w}), int($win->{h}), 1);
                }
            }
        }
    }
    $self->_request_redraw();
    return;
}

sub scale {
    my ($self, $tag_or_id, $ox, $oy, $sx, $sy) = @_;
    $self->{scene}->scale($tag_or_id, $ox + 0, $oy + 0, $sx + 0, $sy + 0);
    $self->_request_redraw();
    return;
}

sub delete {
    my ($self, @targets) = @_;
    for my $t (@targets) {
        if (defined($t) && $t eq 'all') {
            if (defined $self->{tk_surface}) {
                for my $win (values %{ $self->{item_windows} }) {
                    eval { $self->{tk_surface}->remove_child($win->{path}) };
                }
            }
            $self->{scene}->clear();
            %{ $self->{item_opts} }    = ();
            %{ $self->{item_photos} }  = ();
            %{ $self->{item_windows} } = ();
        }
        else {
            my $ids = $self->{scene}->find_withtag($t);
            for my $id (@{ $ids || [] }) {
                delete $self->{item_opts}{$id};
                delete $self->{item_photos}{$id};
                if (my $win = delete $self->{item_windows}{$id}) {
                    eval { $self->{tk_surface}->remove_child($win->{path}) } if defined $self->{tk_surface};
                }
            }
            $self->{scene}->delete_by_tag($t);
        }
    }
    $self->_request_redraw();
    return;
}

sub raise {
    my ($self, $tag_or_id, $above) = @_;
    my $ids = $self->{scene}->find_withtag($tag_or_id);
    my $above_id = 0;
    if (defined $above) {
        my $aids = $self->{scene}->find_withtag($above);
        $above_id = ($aids && @$aids) ? $aids->[-1] : 0;
    }
    for my $id (@{ $ids || [] }) {
        $self->{scene}->raise($id, $above_id);
    }
    $self->_request_redraw();
    return;
}

sub lower {
    my ($self, $tag_or_id, $below) = @_;
    my $ids = $self->{scene}->find_withtag($tag_or_id);
    my $below_id = 0;
    if (defined $below) {
        my $bids = $self->{scene}->find_withtag($below);
        $below_id = ($bids && @$bids) ? $bids->[0] : 0;
    }
    for my $id (@{ $ids || [] }) {
        $self->{scene}->lower($id, $below_id);
    }
    $self->_request_redraw();
    return;
}

sub find {
    my ($self, $mode, @args) = @_;
    my $scene = $self->{scene};
    my $res;
    if ($mode eq 'all') {
        $res = $scene->find_all();
    }
    elsif ($mode eq 'withtag') {
        $res = $scene->find_withtag($args[0]);
    }
    elsif ($mode eq 'overlapping') {
        $res = $scene->find_overlapping($args[0] + 0, $args[1] + 0, $args[2] + 0, $args[3] + 0);
    }
    elsif ($mode eq 'enclosed') {
        $res = $scene->find_enclosed($args[0] + 0, $args[1] + 0, $args[2] + 0, $args[3] + 0);
    }
    elsif ($mode eq 'closest') {
        $res = $scene->find_closest($args[0] + 0, $args[1] + 0, defined($args[2]) ? $args[2] + 0 : 0.0);
    }
    elsif ($mode eq 'above' || $mode eq 'below') {
        my $all = $scene->find_all();
        my $target = $scene->find_withtag($args[0]);
        my $tid = ($target && @$target) ? $target->[0] : 0;
        $res = [];
        for my $idx (0 .. $#$all) {
            if ($all->[$idx] == $tid) {
                if ($mode eq 'above' && $idx < $#$all) {
                    $res = [ $all->[$idx + 1] ];
                }
                elsif ($mode eq 'below' && $idx > 0) {
                    $res = [ $all->[$idx - 1] ];
                }
                last;
            }
        }
    }
    else {
        die "Canvas::find: unsupported search spec '$mode'";
    }
    $res ||= [];
    return wantarray ? @$res : $res;
}

sub addtag {
    my ($self, $newtag, $spec, @args) = @_;
    my $ids = $self->find($spec, @args);
    for my $id (@$ids) {
        $self->{scene}->add_tag($id, $newtag);
    }
    return;
}

sub dtag {
    my ($self, $tag_or_id, $tag_to_del) = @_;
    $tag_to_del = $tag_or_id unless defined $tag_to_del;
    my $ids = $self->{scene}->find_withtag($tag_or_id);
    for my $id (@{ $ids || [] }) {
        $self->{scene}->remove_tag($id, $tag_to_del);
    }
    return;
}

sub gettags {
    my ($self, $tag_or_id) = @_;
    my $ids = $self->{scene}->find_withtag($tag_or_id);
    return wantarray ? () : [] unless $ids && @$ids;
    my $tags = $self->{scene}->get_tags($ids->[0]) || [];
    return wantarray ? @$tags : $tags;
}

sub bind {
    my ($self, @args) = @_;
    # Widget-level bind if 1-2 args or first arg looks like an event sequence <...>
    if (@args <= 2 || (defined $args[0] && substr($args[0], 0, 1) eq '<')) {
        return $self->SUPER::bind(@args) if defined $self->{interp};
        return;
    }
    my ($tag_or_id, $seq, $cb) = @args;
    push @{ $self->{item_bindings}{$seq} }, [ $tag_or_id, $cb ];
    if (defined $self->{interp} && !$self->{bound_seqs}{$seq}++) {
        $self->SUPER::bind($seq, [ sub {
            my ($c, $x, $y) = @_;
            $c->_dispatch_item_event($seq, $x, $y);
        }, Tcl::Tk::MT::Ev('x', 'y') ]);
    }
    return;
}

sub _dispatch_item_event {
    my ($self, $seq, $x, $y) = @_;
    my $list = $self->{item_bindings}{$seq} or return;
    my $hits = $self->{scene}->find_overlapping($x - 1, $y - 1, $x + 1, $y + 1);
    return unless $hits && @$hits;
    my $top_id = $hits->[-1];
    my %top_tags = map { $_ => 1 } (@{ $self->{scene}->get_tags($top_id) || [] }, $top_id, 'all');
    for my $entry (@$list) {
        my ($tag, $cb) = @$entry;
        if ($top_tags{$tag}) {
            if (ref($cb) eq 'CODE') {
                $cb->($self, $top_id, $x, $y);
            }
            elsif (ref($cb) eq 'ARRAY') {
                my ($code, @extra) = @$cb;
                $code->($self, @extra, $top_id, $x, $y);
            }
        }
    }
}

sub bbox {
    my ($self, @targets) = @_;
    my $tag = @targets ? $targets[0] : 'all';
    my $bb  = $self->{scene}->bbox($tag);
    return wantarray ? ($bb ? @$bb : ()) : $bb;
}

# Pan/zoom & scroll views (view-only 3x3 matrix update, zero re-tessellation)
sub set_pan_zoom {
    my ($self, $tx, $ty, $sx, $sy) = @_;
    $self->{pan_x}  = $tx + 0;
    $self->{pan_y}  = $ty + 0;
    $self->{zoom_x} = $sx + 0;
    $self->{zoom_y} = defined($sy) ? ($sy + 0) : ($sx + 0);
    $self->{scene}->set_pan_zoom($self->{pan_x}, $self->{pan_y}, $self->{zoom_x}, $self->{zoom_y});
    $self->_request_redraw();
    return;
}

sub pan {
    my ($self, $dx, $dy) = @_;
    $self->{pan_x} += $dx;
    $self->{pan_y} += $dy;
    $self->{scene}->pan($dx + 0, $dy + 0);
    $self->_request_redraw();
    return;
}

sub zoom {
    my ($self, $factor, $cx, $cy) = @_;
    $cx = 0 unless defined $cx;
    $cy = 0 unless defined $cy;
    $self->{zoom_x} *= $factor;
    $self->{zoom_y} *= $factor;
    $self->{scene}->zoom($factor + 0, $cx + 0, $cy + 0);
    $self->_request_redraw();
    return;
}

sub xview {
    my ($self, $cmd, @args) = @_;
    my ($x0, $x1) = $self->_scroll_bounds_x();
    my $span = ($x1 - $x0) || $self->{width};
    if (!defined $cmd) {
        my $first = (-$self->{pan_x} - $x0) / $span;
        my $last  = $first + ($self->{width} / ($span * $self->{zoom_x}));
        $first = 0 if $first < 0;
        $last  = 1 if $last  > 1;
        return wantarray ? ($first, $last) : [ $first, $last ];
    }
    if ($cmd eq 'moveto') {
        my $frac = $args[0] + 0;
        my $new_tx = -($x0 + $frac * $span);
        $self->set_pan_zoom($new_tx, $self->{pan_y}, $self->{zoom_x}, $self->{zoom_y});
    }
    elsif ($cmd eq 'scroll') {
        my ($n, $what) = @args;
        my $step = ($what && $what =~ /page/i) ? $self->{width} * 0.9 : 20;
        $self->pan(-$n * $step, 0);
    }
    return;
}

sub yview {
    my ($self, $cmd, @args) = @_;
    my ($y0, $y1) = $self->_scroll_bounds_y();
    my $span = ($y1 - $y0) || $self->{height};
    if (!defined $cmd) {
        my $first = (-$self->{pan_y} - $y0) / $span;
        my $last  = $first + ($self->{height} / ($span * $self->{zoom_y}));
        $first = 0 if $first < 0;
        $last  = 1 if $last  > 1;
        return wantarray ? ($first, $last) : [ $first, $last ];
    }
    if ($cmd eq 'moveto') {
        my $frac = $args[0] + 0;
        my $new_ty = -($y0 + $frac * $span);
        $self->set_pan_zoom($self->{pan_x}, $new_ty, $self->{zoom_x}, $self->{zoom_y});
    }
    elsif ($cmd eq 'scroll') {
        my ($n, $what) = @args;
        my $step = ($what && $what =~ /page/i) ? $self->{height} * 0.9 : 20;
        $self->pan(0, -$n * $step);
    }
    return;
}

sub _scroll_bounds_x {
    my ($self) = @_;
    my $sr = $self->{scrollregion};
    if (ref($sr) eq 'ARRAY' && @$sr >= 4) {
        return ($sr->[0], $sr->[2]);
    }
    return (0, $self->{width});
}

sub _scroll_bounds_y {
    my ($self) = @_;
    my $sr = $self->{scrollregion};
    if (ref($sr) eq 'ARRAY' && @$sr >= 4) {
        return ($sr->[1], $sr->[3]);
    }
    return (0, $self->{height});
}

# PostScript export via software/backend RGBA readback
sub postscript {
    my ($self, %opts) = @_;
    my $file = $opts{'-file'} // $opts{file};

    my $w    = $self->{width};
    my $h    = $self->{height};
    my $rgba = $self->readback_rgba();

    # Encode RGB24 hex image for PostScript Level 2 colorimage
    my @lines = (
        '%!PS-Adobe-3.0 EPSF-3.0',
        '%%Creator: Tcl::Tk::MT::Canvas',
        "%%BoundingBox: 0 0 $w $h",
        '%%EndComments',
        'gsave',
        "$w $h scale",
        "$w $h 8 [ $w 0 0 -$h 0 $h ]",
        '{ currentfile ' . ($w * 3) . ' string readhexstring pop } false 3 colorimage',
    );

    my $stride = $w * 4;
    for my $row (0 .. $h - 1) {
        my $row_bytes = substr($rgba, $row * $stride, $stride);
        # Strip alpha channel (every 4th byte) -> RGB
        my $rgb = pack('C*', map {
            my $off = $_ * 4;
            unpack('CCC', substr($row_bytes, $off, 3));
        } 0 .. $w - 1);
        push @lines, unpack('H*', $rgb);
    }
    push @lines, 'grestore', 'showpage', '%%EOF', '';

    my $ps = join("\n", @lines);
    if (defined $file) {
        open my $fh, '>', $file or die "Canvas::postscript: cannot open '$file': $!";
        binmode $fh;
        print {$fh} $ps;
        close $fh or die "Canvas::postscript: close '$file': $!";
    }
    return $ps;
}

sub configure {
    my ($self, @args) = @_;
    return {
        '-width'        => $self->{width},
        '-height'       => $self->{height},
        '-background'   => $self->{background},
        '-scrollregion' => $self->{scrollregion},
    } unless @args;

    my @tk_rest;
    my $resized = 0;
    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        my $v = ($i < @args) ? $args[$i++] : undef;
        my $lk = defined($k) ? $k : '';
        $lk =~ s/\A-//;
        if ($lk eq 'width') {
            $self->{width} = int($v);
            $resized = 1;
        }
        elsif ($lk eq 'height') {
            $self->{height} = int($v);
            $resized = 1;
        }
        elsif ($lk eq 'bg' || $lk eq 'background') {
            $self->{background} = $v;
            $self->{scene}->set_clear_color(Tcl::Tk::MT::Gfx::parse_color($v), 1);
            $self->_request_redraw();
        }
        elsif ($lk eq 'scrollregion') {
            $self->{scrollregion} = ref($v) eq 'ARRAY' ? $v : [ split /\s+/, $v ];
        }
        else {
            push @tk_rest, (Tcl::Tk::MT::_norm_opt($k), $v);
        }
    }

    if ($resized) {
        $self->{scene}->set_viewport($self->{width}, $self->{height});
        $self->{gfx_surface}->resize($self->{width}, $self->{height}, $self->{gfx_surface}->scale());
        $self->_request_redraw();
    }
    if (@tk_rest && defined $self->{interp}) {
        $self->SUPER::configure(@tk_rest);
    }
    return;
}

sub cget {
    my ($self, $opt) = @_;
    my $lk = $opt;
    $lk =~ s/\A-//;
    return $self->{width}        if $lk eq 'width';
    return $self->{height}       if $lk eq 'height';
    return $self->{background}   if $lk eq 'bg' || $lk eq 'background';
    return $self->{scrollregion} if $lk eq 'scrollregion';
    return $self->SUPER::cget($opt) if defined $self->{interp};
    return undef;
}

sub destroy {
    my ($self) = @_;
    if (defined $self->{tk_surface}) {
        eval { $self->{tk_surface}->destroy() };
        $self->{tk_surface} = undef;
    }
    return $self->SUPER::destroy() if defined $self->{interp} && defined $self->{path};
    return;
}

# =============================================================================
# Batched and packed-array primitives (SVf_PACKED_AV fast paths)
# =============================================================================

sub batch {
    my ($self, $code) = @_;
    die "Canvas::batch requires a CODE ref" unless ref($code) eq 'CODE';
    $self->{scene}->batch_begin();
    my $wantarray = wantarray;
    my (@res, $res);
    my $ok = eval {
        if ($wantarray) {
            @res = $code->($self);
        }
        else {
            $res = $code->($self);
        }
        1;
    };
    my $err = $@;
    $self->{scene}->batch_end();
    $self->_request_redraw() if $self->{scene}->batch_depth() == 0;
    die $err unless $ok;
    return $wantarray ? @res : $res;
}

sub createLinesBatch {
    my ($self, $packed_nv, $opts) = @_;
    $opts ||= {};
    my $fill  = exists $opts->{'-fill'}  ? $opts->{'-fill'}  : ($opts->{fill}  // 'black');
    my $width = exists $opts->{'-width'} ? $opts->{'-width'} : ($opts->{width} // 1.0);
    my $rgba  = Tcl::Tk::MT::Gfx::parse_color($fill);
    my $count = $self->{scene}->create_lines_batch($packed_nv, $rgba, $width + 0);
    $self->_request_redraw();
    return $count;
}

sub createInstances {
    my ($self, $packed_data, $opts) = @_;
    $opts ||= {};
    my $shape_opt = exists $opts->{'-shape'} ? $opts->{'-shape'} : ($opts->{shape} // 'circle');
    my $shape = looks_like_number($shape_opt) ? int($shape_opt) : ($SHAPE_MAP{lc($shape_opt)} // 2);
    my $aa    = exists $opts->{'-aa'} ? $opts->{'-aa'} : (exists $opts->{aa} ? $opts->{aa} : 1);
    my $flags = exists $opts->{'-flags'} ? int($opts->{'-flags'}) : ($aa ? 1 : 0);
    my $stride = exists $opts->{'-stride'} ? int($opts->{'-stride'}) : (exists $opts->{stride} ? int($opts->{stride}) : 4);
    my $id = $self->{scene}->create_instances($packed_data, $shape, $flags, $stride);
    $self->_request_redraw();
    return $id;
}

sub updateCoordsPacked {
    my ($self, $id, $packed_nv) = @_;
    $self->{scene}->update_coords_packed($id, $packed_nv);
    $self->_request_redraw();
    return;
}

sub submit_batch {
    my ($self, $ops) = @_;
    die "Canvas::submit_batch requires an ARRAY ref of operations" unless ref($ops) eq 'ARRAY';
    my @results;
    $self->batch(sub {
        for my $op (@$ops) {
            next unless ref($op) eq 'ARRAY' && @$op;
            my ($method, @args) = @$op;
            push @results, scalar $self->$method(@args);
        }
    });
    return \@results;
}

1;

__END__

=head1 NAME

Tcl::Tk::MT::Canvas - Retained 2D canvas widget with GPU and software backends

=head1 SYNOPSIS

    use Tcl::Tk::MT;

    my $mw = MainWindow->new(-title => 'Canvas');
    my $c  = $mw->Canvas(-width => 800, -height => 600, -bg => '#10141c')->pack;
    my $id = $c->createRectangle(10, 10, 120, 80, -fill => '#2266cc', -tags => 'box');
    $c->createLinesBatch(\@segments, { -fill => '#58a6ff', -width => 1.5 });
    $c->createInstances(\@xycs, { -shape => 'oval', -aa => 1 });
    $c->render();

=head1 DESCRIPTION

Subclass of C<Tcl::Tk::MT::Widget> backed by a C11 retained 2D scene graph and
spatial index (L<Tcl::Tk::MT::Gfx>). Supports common Tk Canvas item creation,
tagging, hit-testing, scrolling, and rasterized PostScript export alongside
C<SVf_PACKED_AV> batch primitives and view-only pan/zoom transforms.

=head1 METHODS

=over 4

=item C<< Tcl::Tk::MT::Canvas->new($parent, %opts) >>

Create a canvas. Options: C<-width>, C<-height>, C<-bg> / C<-background>,
C<-scrollregion>, C<-backend>, C<-headless>. Pass C<$parent = undef> with
C<< -headless => 1 >> for offscreen rendering without a Tk display.

=item Standard Tk Canvas Items

C<createLine>, C<createRectangle>, C<createOval>, C<createArc>,
C<createPolygon>, C<createText>, C<createImage>, C<createWindow>.

=item Item Manipulation & Queries

C<coords>, C<itemconfigure>, C<itemcget>, C<move>, C<scale>, C<delete>,
C<raise>, C<lower>, C<find> (C<all>, C<withtag>, C<overlapping>, C<enclosed>,
C<closest>, C<above>, C<below>), C<addtag>, C<dtag>, C<gettags>, C<bind>,
C<bbox>, C<configure>, C<cget>, C<destroy>.

=item View Transform & Export

C<set_pan_zoom($tx, $ty, $sx, $sy)>, C<pan($dx, $dy)>,
C<zoom($factor, $cx, $cy)>, C<xview>, C<yview>, C<postscript(-file => $path)>.

=item Batched and Packed Primitives

=over 4

=item C<< $c->batch(sub { ... }) >>

Defer redraw notifications across bulk mutations.

=item C<< $c->createLinesBatch(\@xy_pairs, { -fill => $color, -width => $w }) >>

Create multiple 2-point line segments from packed C<[x0, y0, x1, y1, ...]> data.

=item C<< $c->createInstances(\@data, { -shape => $kind, -aa => $bool, -stride => $n }) >>

Create a GPU-instanced SDF batch (C<rect>, C<rounded_rect>, C<oval> / C<circle>,
C<arc>, C<quad_tex>). Default stride 4 is C<[x, y, rgba_u32, size]>.

=item C<< $c->updateCoordsPacked($id, \@packed_nv) >>

Update item coordinates from a packed NV array or regular arrayref.

=item C<< $c->submit_batch(\@ops) >>

Execute an arrayref of C<[ $method, @args ]> operations inside a single C<batch()>.

=back

=item Rendering & Diagnostics

C<render()>, C<readback_rgba()>, C<readback_sha256()>, C<is_accelerated()>,
C<backend_name()>, C<stats()>, C<scene()>, C<surface()>, C<tk_surface()>.

=back

=head1 LIMITATIONS

Not every native Tk Canvas option is implemented (for example, bitmap stipples
and smooth spline modes). C<postscript()> writes a rasterized RGBA image rather
than vector PostScript. Pass C<< -accel => 0 >> to C<Canvas()> or set
C<TCL_TK_MT_ACCEL=off> to use the native Tk Canvas widget instead.

=head1 SEE ALSO

L<Tcl::Tk::MT>, L<Tcl::Tk::MT::Gfx>, L<Tcl::Tk::MT::Photo>.

=cut
