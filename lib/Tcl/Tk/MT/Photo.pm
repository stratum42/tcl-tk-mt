package Tcl::Tk::MT::Photo;

use strict;
use warnings;
use Scalar::Util qw(blessed refaddr);
use Tcl::Tk::MT::Gfx ();
use overload
    '""'     => sub { $_[0]->tk_photo() },
    'bool'   => sub { 1 },
    fallback => 1;

our $VERSION = '0.01';
my $PHOTO_SEQ = 0;

sub new {
    my ($class, @args) = @_;
    my $interp;
    if (@args && blessed($args[0]) && $args[0]->can('icall')) {
        $interp = shift @args;
    }
    elsif (@args && blessed($args[0]) && $args[0]->can('interp')) {
        $interp = (shift @args)->interp;
    }

    my %opts;
    my $i = 0;
    while ($i < @args) {
        my $k = $args[$i++];
        $k =~ s/\A-// if defined $k && !ref($k);
        my $v = ($i < @args) ? $args[$i++] : undef;
        $opts{$k} = $v if defined $k;
    }

    $interp ||= $opts{interp} || $Tcl::Tk::MT::DEFAULT_INTERP;
    my $name = $opts{name} || ('tkmt_photo_' . (++$PHOTO_SEQ));

    my $self = bless {
        interp    => $interp,
        name      => $name,
        width     => $opts{width}  || 0,
        height    => $opts{height} || 0,
        surface   => $opts{surface},
        tex_map   => {},   # refaddr($surf) => { surf => $surf, tex_id => $id, ver => $v }
        version   => 0,
        last_data => undef,
        tk_name   => undef,
        tk_dirty  => 0,
    }, $class;

    if (defined $opts{rgba} && $self->{width} > 0 && $self->{height} > 0) {
        $self->put_rgba_packed($opts{rgba}, $self->{width}, $self->{height});
    }
    elsif ((defined $opts{file} || defined $opts{data}) && defined $interp) {
        my @tk_args;
        for my $k (qw(file data format gamma palette width height)) {
            push @tk_args, ("-$k", $opts{$k}) if defined $opts{$k};
        }
        $self->{tk_name} = $interp->icall_scalar(
            'image', 'create', 'photo', $name, @tk_args
        );
        $self->{width}  = int($interp->icall_scalar('image', 'width',  $self->{tk_name}) || 0);
        $self->{height} = int($interp->icall_scalar('image', 'height', $self->{tk_name}) || 0);
    }

    return $self;
}

sub name   { $_[0]{name} }
sub width  { $_[0]{width} }
sub height { $_[0]{height} }
sub interp { $_[0]{interp} }

sub attach_surface {
    my ($self, $surf) = @_;
    $self->{surface} = $surf;
    return $self->ensure_texture($surf) if defined $self->{last_data} && $self->{width} > 0 && $self->{height} > 0;
    return 0;
}

# Zero-copy upload of RGBA8888 pixel data (packed AV_PACKED_U8 arrayref or raw byte scalar)
sub put_rgba_packed {
    my ($self, $data, $w, $h) = @_;
    $w = $self->{width}  unless defined $w;
    $h = $self->{height} unless defined $h;
    die "Photo::put_rgba_packed requires positive width and height"
        unless defined($w) && defined($h) && $w > 0 && $h > 0;

    $self->{width}     = int($w);
    $self->{height}    = int($h);
    $self->{last_data} = $data;
    $self->{version}++;
    $self->{tk_dirty}  = 1;

    # Upload immediately to primary surface and any already-bound surfaces
    my $primary_tex = 0;
    if (defined $self->{surface}) {
        $primary_tex = $self->ensure_texture($self->{surface});
    }
    for my $key (keys %{ $self->{tex_map} }) {
        my $entry = $self->{tex_map}{$key};
        next if $entry->{ver} == $self->{version};
        my $surf = $entry->{surf} or next;
        $entry->{tex_id} = $surf->put_rgba_packed($entry->{tex_id} || 0, $self->{width}, $self->{height}, $data);
        $entry->{ver}    = $self->{version};
    }

    return $primary_tex;
}

# Ensure GPU/backend texture exists and is up-to-date on $surf; returns tex_id.
sub ensure_texture {
    my ($self, $surf) = @_;
    $surf ||= $self->{surface};
    return 0 unless defined $surf;

    my $key   = refaddr($surf);
    my $entry = $self->{tex_map}{$key};
    if ($entry && $entry->{ver} == $self->{version} && $entry->{tex_id}) {
        return $entry->{tex_id};
    }

    return 0 unless defined $self->{last_data} && $self->{width} > 0 && $self->{height} > 0;

    my $old_id = $entry ? ($entry->{tex_id} || 0) : 0;
    my $new_id = $surf->put_rgba_packed($old_id, $self->{width}, $self->{height}, $self->{last_data});
    $self->{tex_map}{$key} = {
        surf   => $surf,
        tex_id => $new_id,
        ver    => $self->{version},
    };
    return $new_id;
}

sub tex_id {
    my ($self, $surf) = @_;
    $surf ||= $self->{surface};
    return 0 unless defined $surf;
    my $entry = $self->{tex_map}{ refaddr($surf) };
    return $entry ? ($entry->{tex_id} || 0) : 0;
}

# On-demand Tk photo mirror: creates the Tk photo image and blits RGBA data only when asked.
sub sync_to_tk {
    my ($self) = @_;
    my $interp = $self->{interp};
    die "Photo::sync_to_tk requires a Tcl::MT interpreter" unless defined $interp;

    unless (defined $self->{tk_name}) {
        $self->{tk_name} = $interp->icall_scalar(
            'image', 'create', 'photo', $self->{name},
            ($self->{width}  > 0 ? ('-width',  $self->{width})  : ()),
            ($self->{height} > 0 ? ('-height', $self->{height}) : ()),
        );
    }

    if ($self->{tk_dirty} && defined $self->{last_data} && $self->{width} > 0 && $self->{height} > 0) {
        $interp->blit_rgba_photo($self->{tk_name}, $self->{last_data}, $self->{width}, $self->{height});
        $self->{tk_dirty} = 0;
    }

    return $self->{tk_name};
}

sub tk_photo {
    my ($self) = @_;
    return $self->sync_to_tk();
}

sub configure {
    my ($self, @args) = @_;
    my $tk_name = $self->tk_photo();
    return $self->{interp}->icall($tk_name, 'configure', @args);
}

sub cget {
    my ($self, $opt) = @_;
    my $tk_name = $self->tk_photo();
    $opt = "-$opt" if defined $opt && substr($opt, 0, 1) ne '-';
    return $self->{interp}->icall_scalar($tk_name, 'cget', $opt);
}

for my $subcmd (qw(write copy blank put get redither transparency)) {
    no strict 'refs';
    *{"Tcl::Tk::MT::Photo::$subcmd"} = sub {
        my ($self, @args) = @_;
        my $tk_name = $self->tk_photo();
        return $self->{interp}->icall($tk_name, $subcmd, @args);
    };
}

sub destroy {
    my ($self) = @_;
    for my $key (keys %{ $self->{tex_map} }) {
        my $entry = delete $self->{tex_map}{$key};
        if ($entry && $entry->{surf} && $entry->{tex_id}) {
            eval { $entry->{surf}->texture_destroy($entry->{tex_id}) };
        }
    }
    if (defined $self->{tk_name} && defined $self->{interp}) {
        eval { $self->{interp}->icall('image', 'delete', $self->{tk_name}) };
        $self->{tk_name} = undef;
    }
    $self->{last_data} = undef;
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    $self->destroy();
}

1;

__END__

=head1 NAME

Tcl::Tk::MT::Photo - Texture-backed Photo image with on-demand Tk mirroring

=head1 SYNOPSIS

    use Tcl::Tk::MT::Photo;

    my $photo = Tcl::Tk::MT::Photo->new($interp, -width => 256, -height => 256);
    $photo->put_rgba_packed($rgba_bytes_or_packed_u8, 256, 256);
    $canvas->createImage(10, 10, -image => $photo);

    # Materialize a Tk photo image only when needed by standard Tk widgets:
    my $tk_name = $photo->tk_photo();

=head1 DESCRIPTION

Manages RGBA8888 image data as backend GPU textures (supporting zero-copy
C<AV_PACKED_U8> and raw byte strings) while deferring Tk C<image create photo>
creation until C<sync_to_tk()> or C<tk_photo()> is called.

=head1 METHODS

=over 4

=item C<< Tcl::Tk::MT::Photo->new($interp_or_widget, %opts) >>

Create a photo object. Options: C<-name>, C<-width>, C<-height>, C<-surface>,
C<-rgba>, C<-file>, C<-interp>.

=item C<< $photo->put_rgba_packed($data, $width, $height) >>

Upload RGBA8888 pixel data (packed C<AV_PACKED_U8> arrayref or raw byte string)
to attached surfaces and mark the Tk photo mirror dirty. Returns the primary
backend texture ID.

=item C<< $photo->attach_surface($gfx_surface) >> / C<< $photo->ensure_texture($gfx_surface) >> / C<< $photo->tex_id($gfx_surface) >>

Bind and synchronize the texture on a C<Tcl::Tk::MT::Gfx::Surface>.

=item C<< $photo->sync_to_tk() >> / C<< $photo->tk_photo() >>

Create (if needed) and update the backing Tk photo image, returning its Tk image name.

=item C<name()>, C<width()>, C<height()>, C<interp()>, C<destroy()>

Accessors and explicit resource cleanup.

=back

=head1 SEE ALSO

L<Tcl::Tk::MT>, L<Tcl::Tk::MT::Canvas>, L<Tcl::Tk::MT::Gfx>.

=cut
