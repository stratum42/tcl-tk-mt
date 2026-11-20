# Tcl::Tk::MT

A C11 XS bridge to Tcl/Tk 8.6 and 9.x with an optional retained 2D canvas
renderer (Metal, Vulkan, or software) and cooperative integration with
`perl5-mt`. It builds and runs on both `perl5-mt` and stock Perl 5.16+ across
macOS, Linux, and Windows (Win64).

## Overview

- **C11 XS for `perl5-mt` and stock Perl 5**: Built with `PERL_NO_GET_CONTEXT`
  and `PERL_XS_THREADSAFE`. Exports `_mt_threadsafe_boot_Tcl__MT` and
  `_mt_threadsafe_boot_Tcl__Tk__MT__Gfx` when compiled against `perl5-mt`, and
  falls back to standard XS paths on stock Perl 5.16+.
- **Tcl/Tk 8.6 and 9.x bridge (`Tcl::MT`)**:
  - Direct `SV <-> Tcl_Obj` conversion and `Tcl_EvalObjv` dispatch with an
    interned `Tcl_Obj*` cache for commands and option names.
  - Owning UI-thread check and a lock-free C11 MPSC marshal queue
    (`Tcl_ThreadQueueEvent` + `Tcl_ThreadAlert`) for queueing work from other
    OS threads back onto the Tk thread.
- **Retained 2D canvas and graphics backends (`Tcl::Tk::MT::Gfx`)**:
  - **macOS Metal (`c/gfx/gfx_metal.m`)**: Objective-C backend using a child
    `CAMetalLayer` view (`TKMTMetalView`) for windowed rendering and an
    offscreen `MTLTexture` for readback.
  - **Linux and Windows Vulkan (`c/gfx/gfx_vulkan.c`)**: Loads
    `libvulkan.so.1` or `vulkan-1.dll` at runtime (no build-time Vulkan SDK
    dependency), supporting X11, Wayland, Win32, and headless offscreen
    staging.
  - **Software rasterizer (`c/gfx/gfx_software.c`)**: Deterministic C11
    RGBA8888 reference backend with a built-in FIPS 180-4 SHA-256 helper for
    readback verification.
- **Portable threading helpers (`c/tkmt_thread.h`)**: Header-only wrapper over
  POSIX pthreads and Win32 synchronization primitives (`CRITICAL_SECTION`,
  `SRWLOCK`, `CONDITION_VARIABLE`, `CreateThread`, `GetSystemInfo`).
- **Optional FreeType and HarfBuzz text shaping**: Auto-detected via
  `pkg-config` at build time, with a built-in 8x8 bitmap fallback when absent.

## Architecture

```
Perl (perl5-mt or stock Perl 5)
 ├── Tcl::MT                   (xs/TclMT.xs -> c/tcl_bridge/tcl_bridge.c, tk_surface.c)
 │     ├── Lock-free MPSC UI marshal queue (c/tkmt_thread.h + Tcl_ThreadAlert)
 │     └── Native host surface handles (macOS NSView, Linux X11 Display/Window, Win64 HWND)
 └── Tcl::Tk::MT               (lib/Tcl/Tk/MT.pm, Canvas.pm, Photo.pm, Dispatch.pm, Shim.pm)
       └── Tcl::Tk::MT::Gfx    (xs/TkMTGfx.xs)
             ├── Retained scene & tessellator (c/scene/scene.c, tessellate.c, atlas.c)
             └── Graphics backends            (c/gfx/gfx_registry.c, gfx_metal.m, gfx_vulkan.c, gfx_software.c)
```

## Build & Test

### macOS (Apple Silicon / Intel)

```sh
brew install tcl-tk freetype harfbuzz pkg-config

# Against perl5-mt
/path/to/perl5-mt/perl -I/path/to/perl5-mt/lib Makefile.PL
make -j$(sysctl -n hw.ncpu)
/path/to/perl5-mt/perl -I/path/to/perl5-mt/lib -Iblib/arch -Iblib/lib \
    -MTest::Harness -e 'runtests(@ARGV)' \
    t/01*.t t/02*.t t/03*.t t/04*.t t/05*.t t/07*.t t/08*.t t/09*.t

# Against stock Perl 5
perl Makefile.PL
make -j$(sysctl -n hw.ncpu)
prove -b -v t/01*.t t/02*.t t/03*.t t/04*.t t/05*.t t/07*.t t/08*.t t/09*.t
```

### Linux (Ubuntu / Debian / RHEL / Fedora)

```sh
# Ubuntu / Debian
sudo apt-get install -y build-essential pkg-config tcl-dev tk-dev \
    libfreetype-dev libharfbuzz-dev libvulkan1

perl Makefile.PL
make -j$(nproc)
prove -b -v t/01*.t t/02*.t t/03*.t t/04*.t t/06*.t t/07*.t t/08*.t t/09*.t

# Headless CI
xvfb-run -a prove -b -v \
    t/01*.t t/02*.t t/03*.t t/04*.t t/06*.t t/07*.t t/08*.t t/09*.t
```

### Windows (Win64: MSYS2 MinGW-w64 / Strawberry Perl / MSVC)

#### MSYS2 UCRT64 / MINGW64

```sh
pacman -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-make \
          mingw-w64-ucrt-x86_64-pkgconf mingw-w64-ucrt-x86_64-perl \
          mingw-w64-ucrt-x86_64-tcl mingw-w64-ucrt-x86_64-tk

export TCL_CONFIG="$MINGW_PREFIX/lib/tclConfig.sh"
export TK_CONFIG="$MINGW_PREFIX/lib/tkConfig.sh"
perl Makefile.PL
mingw32-make -j$(nproc)
prove -b -v t/01_tcl_mt_bridge.t t/02_gfx_registry.t t/03_scene_hit_test.t t/04_software_render.t
```

#### Strawberry Perl / MSVC

Point `TCL_ROOT` / `TK_ROOT` (or `TCL_CONFIG` / `TK_CONFIG`) to your Tcl/Tk
installation:

```bat
set TCL_ROOT=C:\Tcl
set TK_ROOT=C:\Tcl
perl Makefile.PL
gmake          :: Strawberry Perl (or nmake for MSVC)
prove -b -v t\01_tcl_mt_bridge.t t\02_gfx_registry.t t\03_scene_hit_test.t t\04_software_render.t
```

## Usage

### Compatibility Shim for Existing `Tcl::Tk` Scripts

Run an existing `Tcl::Tk` script through `Tcl::Tk::MT::Shim` without editing
the script:

```sh
perl -MTcl::Tk::MT=:dropin your_app.pl
```

### Batched and Packed Canvas Methods

- `$canvas->createLinesBatch(\@packed_segments, { -fill => $color, -width => $w })`:
  add a batch of 2-point line segments from `[x0, y0, x1, y1, ...]`.
- `$canvas->createInstances(\@packed_xycs, { -shape => 'oval' })`:
  draw instanced SDF shapes (`rect`, `rounded_rect`, `oval`, `arc`, `quad_tex`)
  from packed `MT::Array` or regular arrayref buffers (`SVf_PACKED_AV` fast
  path when available).
- `$canvas->updateCoordsPacked($id, \@packed_coords)`:
  update item coordinates directly from a packed NV array or arrayref.
- `$photo->put_rgba_packed($rgba_bytes, $w, $h)`:
  upload RGBA8888 pixels to backend textures, creating the Tk Photo mirror only
  when `$photo->tk_photo()` is requested.
- `$canvas->batch(sub { ... })`:
  coalesce redraw notifications across bulk item updates.
- `bench/bench_canvas.pl`:
  microbenchmark comparing software, GPU, and native Tk canvas paths.

### Concurrency (`MT::Fiber` and Worker Marshaling)

- `Tcl::Tk::MT::Dispatch` pumps cooperative `MT::Fiber` tasks and `MT::Channel`
  subscriptions from inside `MainLoop` (falling back to in-process queues on
  stock Perl 5).
- Worker threads can send Tcl commands back to the owning Tk thread with
  `$interp->marshal_eval_async($script)` and
  `$interp->marshal_eval_sync($script)`.

## Trade-offs & Limitations

- **Single-thread Tk affinity**: Tcl and Tk interpreters still belong to the OS
  thread that created them. Worker threads cannot call Tk widgets directly and
  must go through the marshal queue or channels.
- **Canvas coverage**: `Tcl::Tk::MT::Canvas` implements the common 2D canvas
  items, tags, hit-testing, scrolling, and view transforms, but does not cover
  every Tk canvas option (such as bitmap stipples or smooth spline modes).
  PostScript export currently writes a rasterized RGBA image rather than vector
  PostScript. Pass `-accel => 0` to `Canvas()` or set `TCL_TK_MT_ACCEL=off` to
  use the native Tk canvas.
- **Vulkan shaders**: `c/gfx/shaders/canvas2d_spv.h` ships with
  `TKMT_HAVE_SPIRV_MODULES` set to `0` so building does not require
  `glslangValidator` or `glslc`. In that default configuration, the Vulkan
  backend initializes Vulkan and stages software-rasterized output through
  Vulkan memory rather than running compiled SPIR-V shaders.
- **Text fallback**: Without FreeType and HarfBuzz at build time, canvas text
  falls back to an 8x8 bitmap font with basic ASCII coverage and no complex
  shaping.
- **Drop-in shim scope**: `Tcl::Tk::MT::Shim` covers common `Tcl::Tk` and
  `Tcl::pTk` usage, not every internal method or third-party widget wrapper in
  those distributions.

## Companion Repositories

Standalone programs built on `Tcl::Tk::MT`:

- [`tkmark`](../tkmark): *TkMark Studio*, a canvas benchmark suite (Fractal,
  Boids, Telemetry Chart) with a companion XS module (`TkMark::Compute`).
- [`neon-bastion`](../neon-bastion): *NEON BASTION*, a tower-defense game with
  a companion XS simulation module (`NeonBastion::SimXS`).

## Environment Variables

| Variable | Values | Purpose |
|---|---|---|
| `TCL_TK_MT_ACCEL` | `auto` \| `metal` \| `vulkan` \| `software` \| `off` | Select the active graphics backend |
| `PERL_FORCE_SCALAR` | `1` \| `0` | Force the software backend when `TCL_TK_MT_ACCEL=auto` |
| `TCL_CONFIG` / `TCL_CONFIG_SH` | Path | Override `tclConfig.sh` lookup |
| `TK_CONFIG` / `TK_CONFIG_SH` | Path | Override `tkConfig.sh` lookup |
| `TCL_ROOT` / `TK_ROOT` | Directory | Prefix root for Tcl/Tk headers and libraries (useful on Win64) |
| `TKMT_FONT_PATH` | Path | Override the TrueType/OpenType font file for FreeType/HarfBuzz |

## Acknowledgments

This distribution owes its design and much of its API shape to the work of
Vadim Konovalov, Christopher Chavez, and the many contributors to `Tcl`,
`Tcl::Tk`, `Tcl::pTk`, Tcl/Tk, and Perl 5.

## License

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl 5 itself.
