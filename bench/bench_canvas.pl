#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Time::HiRes  qw(time);

use FindBin;
use lib "$FindBin::Bin/../blib/lib", "$FindBin::Bin/../blib/arch", "$FindBin::Bin/../lib";

use Tcl::Tk::MT;
use Tcl::Tk::MT::Gfx;
use Tcl::Tk::MT::Canvas;
use Tcl::Tk::MT::Dispatch;

my $count    = 100_000;
my $frames   = 30;
my $width    = 1024;
my $height   = 768;
my $headless = 1;
my $backends_opt = '';

GetOptions(
    'count=i'    => \$count,
    'frames=i'   => \$frames,
    'width=i'    => \$width,
    'height=i'   => \$height,
    'headless!'  => \$headless,
    'backends=s' => \$backends_opt,
) or die "Usage: $0 [--count=N] [--frames=N] [--width=W] [--height=H] [--headless] [--backends=metal,software,off]\n";

Tcl::Tk::MT::Gfx::init();

my @backends;
if ($backends_opt) {
    @backends = split /,/, $backends_opt;
}
else {
    push @backends, 'metal'    if Tcl::Tk::MT::Gfx::backend_available('metal');
    push @backends, 'vulkan'   if Tcl::Tk::MT::Gfx::backend_available('vulkan');
    push @backends, 'software' if Tcl::Tk::MT::Gfx::backend_available('software');
    push @backends, 'off'      unless $headless;
}

my $use_packed = Tcl::Tk::MT::Dispatch::has_packed_av() && Tcl::Tk::MT::Gfx::have_packed_av();

printf "=== Tcl::Tk::MT Canvas Benchmark ===\n";
printf "Perl: %s (perl5-mt=%d, packed_av=%d) | Viewport: %dx%d | N=%d | Frames=%d | Headless=%d\n\n",
    $^V, Tcl::Tk::MT::Gfx::is_perl5_mt(), $use_packed ? 1 : 0, $width, $height, $count, $frames, $headless;

# Pre-generate deterministic benchmark geometry once
my (@line_coords, @inst_data);
srand(42);
for my $i (0 .. $count - 1) {
    my $x0 = ($i * 17.3) % $width;
    my $y0 = ($i * 31.7) % $height;
    my $x1 = ($x0 + 12.0 + ($i % 25));
    my $y1 = ($y0 + 8.0  + ($i % 19));
    push @line_coords, $x0, $y0, $x1, $y1;

    my $r = ($i * 53)  & 0xFF;
    my $g = ($i * 97)  & 0xFF;
    my $b = ($i * 193) & 0xFF;
    my $rgba = Tcl::Tk::MT::Gfx::rgba($r, $g, $b, 200);
    my $sz   = 2.0 + ($i % 6);
    push @inst_data, $x0, $y0, $rgba, $sz;
}

my $lines_ref = $use_packed ? MT::Array::packed('NV', @line_coords) : \@line_coords;
my $inst_ref  = $use_packed ? MT::Array::packed('NV', @inst_data)   : \@inst_data;

printf "%-10s | %14s | %14s | %12s | %10s\n",
    'Backend', 'Lines (ms)', 'Scatter (ms)', 'Pan/Zoom FPS', 'Re-tess';
printf "%s\n", ('-' x 72);

for my $be (@backends) {
    if ($be eq 'off') {
        bench_native_tk();
        next;
    }
    unless (Tcl::Tk::MT::Gfx::backend_available($be)) {
        printf "%-10s | %-57s\n", $be, '(not available)';
        next;
    }

    # 1. Lines batch + first render
    my $c1 = Tcl::Tk::MT::Canvas->new(undef,
        -width => $width, -height => $height, -bg => '#0d1117',
        -backend => $be, -headless => 1,
    );
    my $t0 = time();
    $c1->createLinesBatch($lines_ref, { -fill => '#58a6ff', -width => 1.0 });
    $c1->render();
    my $lines_ms = (time() - $t0) * 1000.0;

    # 2. Instanced scatter + first render
    my $c2 = Tcl::Tk::MT::Canvas->new(undef,
        -width => $width, -height => $height, -bg => '#0d1117',
        -backend => $be, -headless => 1,
    );
    my $t1 = time();
    $c2->createInstances($inst_ref, { -shape => 'circle', -aa => 1 });
    $c2->render();
    my $scatter_ms = (time() - $t1) * 1000.0;

    # 3. Pan/zoom FPS on the instanced scatter scene (view-only 3x3 matrix updates)
    my $st_before = $c2->stats();
    my $t2 = time();
    for my $f (1 .. $frames) {
        my $dx = ($f % 2 == 0) ? 2.5 : -1.5;
        my $dy = ($f % 2 == 0) ? 1.5 : -0.5;
        $c2->pan($dx, $dy);
        $c2->zoom(($f % 2 == 0) ? 1.01 : 0.9901, $width * 0.5, $height * 0.5);
        $c2->render();
    }
    my $dt  = time() - $t2;
    my $fps = $dt > 0 ? ($frames / $dt) : 0;
    my $st_after = $c2->stats();
    my $retess = $st_after->{tessellate_count} - $st_before->{tessellate_count};

    printf "%-10s | %11.2f ms | %11.2f ms | %9.1f fps | %10d\n",
        $be, $lines_ms, $scatter_ms, $fps, $retess;
}

sub bench_native_tk {
    my $mw = eval { MainWindow->new() };
    if (!$mw) {
        printf "%-10s | %-57s\n", 'off', '(no Tk display available)';
        return;
    }
    $mw->withdraw();
    my $c = $mw->Canvas(-width => $width, -height => $height, -accel => 0);

    # Cap native Tk canvas to 5,000 items if N is huge so benchmark finishes in seconds
    my $n_tk = $count > 5000 ? 5000 : $count;
    my $scale_factor = $count / $n_tk;

    my $t0 = time();
    for my $i (0 .. $n_tk - 1) {
        my $o = $i * 4;
        $c->createLine($line_coords[$o], $line_coords[$o+1], $line_coords[$o+2], $line_coords[$o+3], -fill => '#58a6ff');
    }
    $mw->update('idletasks');
    my $lines_ms = (time() - $t0) * 1000.0 * $scale_factor;

    my $t2 = time();
    for my $f (1 .. 5) {
        $c->move('all', 2, 1);
        $mw->update('idletasks');
    }
    my $dt  = time() - $t2;
    my $fps = $dt > 0 ? (5 / ($dt * $scale_factor)) : 0;

    printf "%-10s | %10.1f* ms | %14s | %8.1f* fps | %10s\n",
        'off', $lines_ms, 'N/A', $fps, 'always';
    $mw->destroy();
}
