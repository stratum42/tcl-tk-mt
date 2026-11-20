package Tcl::Tk::MT::Gfx;

use strict;
use warnings;
use XSLoader;

our $VERSION = '0.01';

XSLoader::load('Tcl::Tk::MT::Gfx', $VERSION);

# Short aliases
sub list {
    return list_backends();
}

sub active {
    return active_backend();
}

# Fast cached Tk color name / hex -> packed little-endian RGBA8888 (r | g<<8 | b<<16 | a<<24)
my %NAMED_COLORS = (
    ''          => 0x00000000,
    none        => 0x00000000,
    transparent => 0x00000000,
    black       => 0xFF000000,
    white       => 0xFFFFFFFF,
    red         => 0xFF0000FF,
    green       => 0xFF008000,
    lime        => 0xFF00FF00,
    blue        => 0xFFFF0000,
    yellow      => 0xFF00FFFF,
    cyan        => 0xFFFFFF00,
    aqua        => 0xFFFFFF00,
    magenta     => 0xFFFF00FF,
    fuchsia     => 0xFFFF00FF,
    gray        => 0xFF808080,
    grey        => 0xFF808080,
    darkgray    => 0xFFA9A9A9,
    darkgrey    => 0xFFA9A9A9,
    lightgray   => 0xFFD3D3D3,
    lightgrey   => 0xFFD3D3D3,
    silver      => 0xFFC0C0C0,
    orange      => 0xFF00A5FF,
    purple      => 0xFF800080,
    pink        => 0xFFCBC0FF,
    brown       => 0xFF2A2AA5,
    navy        => 0xFF800000,
    teal        => 0xFF808000,
    olive       => 0xFF008080,
    maroon      => 0xFF000080,
    gold        => 0xFF00D7FF,
    coral       => 0xFF507FFF,
    salmon      => 0xFF7280FA,
    indigo      => 0xFF82004B,
    violet      => 0xFFEE82EE,
    skyblue     => 0xFFEBCE87,
    steelblue   => 0xFFB48246,
    darkblue    => 0xFF8B0000,
    darkgreen   => 0xFF006400,
    darkred     => 0xFF00008B,
);

my %COLOR_CACHE = %NAMED_COLORS;

sub parse_color {
    my ($spec) = @_;
    return 0 unless defined $spec;
    # Already a packed integer color if purely numeric
    if ($spec =~ /\A(?:0x[0-9a-fA-F]+|\d+)\z/) {
        return $spec =~ /\A0x/i ? hex($spec) : int($spec);
    }
    return $COLOR_CACHE{$spec} if exists $COLOR_CACHE{$spec};

    my $lc = lc($spec);
    return $COLOR_CACHE{$lc} if exists $COLOR_CACHE{$lc};

    if (substr($lc, 0, 1) eq '#') {
        my $hex = substr($lc, 1);
        my $len = length($hex);
        my ($r, $g, $b, $a) = (0, 0, 0, 255);
        if ($len == 3) {
            $r = hex(substr($hex, 0, 1) x 2);
            $g = hex(substr($hex, 1, 1) x 2);
            $b = hex(substr($hex, 2, 1) x 2);
        }
        elsif ($len == 6) {
            $r = hex(substr($hex, 0, 2));
            $g = hex(substr($hex, 2, 2));
            $b = hex(substr($hex, 4, 2));
        }
        elsif ($len == 8) {
            $r = hex(substr($hex, 0, 2));
            $g = hex(substr($hex, 2, 2));
            $b = hex(substr($hex, 4, 2));
            $a = hex(substr($hex, 6, 2));
        }
        elsif ($len == 12) {
            # Tk 16-bit per channel #RRRRGGGGBBBB
            $r = hex(substr($hex, 0, 2));
            $g = hex(substr($hex, 4, 2));
            $b = hex(substr($hex, 8, 2));
        }
        my $packed = rgba($r, $g, $b, $a);
        $COLOR_CACHE{$spec} = $packed;
        return $packed;
    }

    # Gray0..Gray100
    if ($lc =~ /\Agr[ae]y(\d+)\z/) {
        my $v = int($1 * 255 / 100 + 0.5);
        $v = 255 if $v > 255;
        my $packed = rgba($v, $v, $v, 255);
        $COLOR_CACHE{$spec} = $packed;
        return $packed;
    }

    # Fallback: opaque black
    return 0xFF000000;
}

1;

__END__

=head1 NAME

Tcl::Tk::MT::Gfx - Graphics backend registry, surface, and retained scene XS API

=head1 SYNOPSIS

    use Tcl::Tk::MT::Gfx;

    Tcl::Tk::MT::Gfx::init();
    my $active   = Tcl::Tk::MT::Gfx::active_backend();
    my $backends = Tcl::Tk::MT::Gfx::list_backends();
    my $surf     = Tcl::Tk::MT::Gfx::create_surface(640, 480, undef, 1.0, 1);
    my $scene    = Tcl::Tk::MT::Gfx::create_scene(640, 480);
    $scene->render($surf);

=head1 DESCRIPTION

Low-level XS interface to the C11 graphics backend registry (Metal, Vulkan,
Software CPU), offscreen/windowed surfaces, RGBA8/R8 textures, and the
retained 2D scene graph.

=head1 FUNCTIONS

=over 4

=item C<init()> / C<shutdown()> / C<reset_for_test($mode)>

Initialize or shut down the graphics backend registry.

=item C<active_backend()> / C<active()> / C<active_backend_info()> / C<list_backends()> / C<list()> / C<backend_available($name)> / C<is_enabled()>

Inspect registered and active backends.

=item C<stats()> / C<reset_stats()>

Retrieve or reset global rendering telemetry counters.

=item C<rgba($r, $g, $b, $a)> / C<parse_color($spec)>

Pack 8-bit channels or parse Tk color names/hex strings (C<#rgb>, C<#rrggbb>,
C<#rrggbbaa>, C<#rrrrggggbbbb>, C<gray0..100>) into little-endian RGBA8888.

=item C<sha256_hex($bytes)>

Compute a 64-character lowercase FIPS 180-4 SHA-256 hex digest.

=item C<create_surface($w, $h, $backend, $scale, $headless, $native_surface_ptr)>

Create a C<Tcl::Tk::MT::Gfx::Surface> handle supporting C<backend_name()>,
C<width()>, C<height()>, C<scale()>, C<resize()>, C<texture_create_rgba()>,
C<texture_update_rgba()>, C<put_rgba_packed()>, C<texture_destroy()>,
C<readback_rgba()>, and C<readback_sha256()>.

=item C<create_scene($w, $h)>

Create a C<Tcl::Tk::MT::Gfx::Scene> handle supporting item CRUD, styling,
tags, spatial queries (C<find_all>, C<find_withtag>, C<find_overlapping>,
C<find_enclosed>, C<find_closest>, C<bbox>), batching (C<batch_begin>,
C<batch_end>, C<batch_depth>), view transforms (C<set_view_matrix>,
C<get_view_matrix>, C<set_pan_zoom>, C<pan>, C<zoom>), bulk geometry
(C<create_lines_batch>, C<create_instances>, C<update_coords_packed>),
C<tessellate()>, C<render($surf)>, C<stats()>, and C<atlas_using_freetype()>.

=item C<is_perl5_mt()> / C<have_packed_av()> / C<av_packed_type($aref)>

Query C<perl5-mt> build and packed-array capabilities.

=back

=head1 SEE ALSO

L<Tcl::Tk::MT>, L<Tcl::Tk::MT::Canvas>, L<Tcl::Tk::MT::Photo>.

=cut
