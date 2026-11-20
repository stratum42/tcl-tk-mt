use strict;
use warnings;
use Config;
use ExtUtils::MakeMaker;

my $is_darwin = ($^O eq 'darwin');
my $is_linux  = ($^O eq 'linux');
my $is_win32  = ($^O eq 'MSWin32');
my $devnull   = $is_win32 ? 'NUL' : '/dev/null';

my $CFG_CC    = $Config{cc} || 'cc';
my $is_msvc   = ($is_win32 && $CFG_CC =~ /(?:^|[\\\/])cl(?:\.exe)?$/i) ? 1 : 0;

# ---- Parse shell key='value' assignments from tclConfig.sh / tkConfig.sh ----
sub parse_config_sh {
    my ($path) = @_;
    return () unless defined $path && -r $path;
    open my $fh, '<', $path or return ();
    my %cfg;
    while (my $line = <$fh>) {
        $line =~ s/\r?\n$//;
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
        if ($line =~ /^([A-Za-z0-9_]+)='(.*)'\s*$/) {
            $cfg{$1} = $2;
        } elsif ($line =~ /^([A-Za-z0-9_]+)="([^"]*)"\s*$/) {
            $cfg{$1} = $2;
        } elsif ($line =~ /^([A-Za-z0-9_]+)=([^\s'"]+)\s*$/) {
            $cfg{$1} = $2;
        }
    }
    close $fh;
    return %cfg;
}

sub find_config_sh {
    my ($env_keys_ref, @candidates) = @_;
    for my $env_key (@$env_keys_ref) {
        if (defined $ENV{$env_key} && length $ENV{$env_key} && -r $ENV{$env_key}) {
            return $ENV{$env_key};
        }
    }
    for my $p (@candidates) {
        next unless defined $p && length $p;
        return $p if -r $p;
    }
    return undef;
}

# Build platform-ordered candidate list for tclConfig.sh / tkConfig.sh
my (@tcl_candidates, @tk_candidates);

if (defined $ENV{TCL_ROOT} && length $ENV{TCL_ROOT}) {
    my $r = $ENV{TCL_ROOT};
    $r =~ s{[\\/]+$}{};
    push @tcl_candidates, "$r/lib/tclConfig.sh", "$r/lib64/tclConfig.sh";
}
if (defined $ENV{TK_ROOT} && length $ENV{TK_ROOT}) {
    my $r = $ENV{TK_ROOT};
    $r =~ s{[\\/]+$}{};
    push @tk_candidates, "$r/lib/tkConfig.sh", "$r/lib64/tkConfig.sh";
} elsif (defined $ENV{TCL_ROOT} && length $ENV{TCL_ROOT}) {
    my $r = $ENV{TCL_ROOT};
    $r =~ s{[\\/]+$}{};
    push @tk_candidates, "$r/lib/tkConfig.sh", "$r/lib64/tkConfig.sh";
}

if ($is_win32) {
    my @win_roots;
    push @win_roots, $ENV{MINGW_PREFIX} if defined $ENV{MINGW_PREFIX} && length $ENV{MINGW_PREFIX};
    push @win_roots, (
        'C:/msys64/ucrt64',
        'C:/msys64/mingw64',
        'C:/msys64/clang64',
        'C:/Tcl',
        'C:/ActiveTcl',
        'C:/Strawberry/c',
    );
    for my $r (@win_roots) {
        push @tcl_candidates, "$r/lib/tclConfig.sh";
        push @tk_candidates,  "$r/lib/tkConfig.sh";
    }
} elsif ($is_darwin) {
    push @tcl_candidates, (
        '/opt/homebrew/opt/tcl-tk/lib/tclConfig.sh',
        '/opt/homebrew/opt/tcl-tk@8/lib/tclConfig.sh',
        '/usr/local/opt/tcl-tk/lib/tclConfig.sh',
        '/usr/local/lib/tclConfig.sh',
    );
    push @tk_candidates, (
        '/opt/homebrew/opt/tcl-tk/lib/tkConfig.sh',
        '/opt/homebrew/opt/tcl-tk@8/lib/tkConfig.sh',
        '/usr/local/opt/tcl-tk/lib/tkConfig.sh',
        '/usr/local/lib/tkConfig.sh',
    );
} else {
    push @tcl_candidates, (
        '/usr/lib/x86_64-linux-gnu/tclConfig.sh',
        '/usr/lib/aarch64-linux-gnu/tclConfig.sh',
        '/usr/lib/tcl9.0/tclConfig.sh',
        '/usr/lib/tcl8.6/tclConfig.sh',
        '/usr/lib64/tclConfig.sh',
        '/usr/lib/tclConfig.sh',
        '/usr/local/lib/tclConfig.sh',
    );
    push @tk_candidates, (
        '/usr/lib/x86_64-linux-gnu/tkConfig.sh',
        '/usr/lib/aarch64-linux-gnu/tkConfig.sh',
        '/usr/lib/tk9.0/tkConfig.sh',
        '/usr/lib/tk8.6/tkConfig.sh',
        '/usr/lib64/tkConfig.sh',
        '/usr/lib/tkConfig.sh',
        '/usr/local/lib/tkConfig.sh',
    );
}

my $tcl_cfg_path = find_config_sh(['TCL_CONFIG', 'TCL_CONFIG_SH'], @tcl_candidates);
my $tk_cfg_path  = find_config_sh(['TK_CONFIG',  'TK_CONFIG_SH'],  @tk_candidates);

my %tcl_cfg = parse_config_sh($tcl_cfg_path);
my %tk_cfg  = parse_config_sh($tk_cfg_path);

my $tcl_inc  = $tcl_cfg{TCL_INCLUDE_SPEC} // '';
my $tk_inc   = $tk_cfg{TK_INCLUDE_SPEC}   // '';
my $tk_xinc  = $tk_cfg{TK_XINCLUDES}      // '';
my $tcl_libs = $tcl_cfg{TCL_LIB_SPEC}     // '';
my $tk_libs  = $tk_cfg{TK_LIB_SPEC}       // '';

# Fallback to pkg-config or root heuristics if tclConfig.sh / tkConfig.sh not found
if (!$tcl_libs) {
    my $pc_inc  = `pkg-config --cflags tcl tk 2>$devnull`;
    my $pc_libs = `pkg-config --libs tcl tk 2>$devnull`;
    if ($? == 0 && defined $pc_libs && $pc_libs =~ /\S/) {
        $pc_inc  =~ s/\r?\n$// if defined $pc_inc;
        $pc_libs =~ s/\r?\n$//;
        $tcl_inc  = $pc_inc // '';
        $tcl_libs = $pc_libs;
    } elsif ($is_win32) {
        my $root = $ENV{TCL_ROOT} || $ENV{MINGW_PREFIX} || 'C:/msys64/ucrt64';
        $root =~ s{[\\/]+$}{};
        $tcl_inc  = "-I$root/include";
        $tcl_libs = $is_msvc ? "\"$root/lib/tcl86t.lib\"" : "-L$root/lib -ltcl86";
        $tk_libs  = $is_msvc ? "\"$root/lib/tk86t.lib\""  : "-L$root/lib -ltk86";
    } else {
        $tcl_inc  = '-I/usr/include/tcl8.6 -I/usr/include/tcl';
        $tcl_libs = '-ltcl8.6';
        $tk_libs  = '-ltk8.6';
    }
}

# Deduplicate include flags
my @inc_parts = ('-I.', '-Ixs', '-Ic', '-Ic/tcl_bridge', '-Ic/scene', '-Ic/gfx');
my %seen_inc;
for my $chunk ($tcl_inc, $tk_inc, $tk_xinc) {
    next unless defined $chunk && length $chunk;
    for my $tok (split /\s+/, $chunk) {
        next unless length $tok;
        next if $seen_inc{$tok}++;
        push @inc_parts, $tok;
    }
}

# ---- Detect FreeType + HarfBuzz via pkg-config (optional on all platforms) ----
my $ft_hb_defines = '';
my $ft_hb_libs    = '';
{
    my $cflags = `pkg-config --cflags freetype2 harfbuzz 2>$devnull`;
    my $libs   = `pkg-config --libs freetype2 harfbuzz 2>$devnull`;
    if ($? == 0 && defined $libs && $libs =~ /-lfreetype/ && $libs =~ /-lharfbuzz/) {
        $cflags =~ s/\r?\n$// if defined $cflags;
        $libs   =~ s/\r?\n$//;
        $ft_hb_defines = '-DTKMT_HAVE_FREETYPE_HARFBUZZ=1';
        $ft_hb_libs    = $libs;
        for my $tok (split /\s+/, ($cflags // '')) {
            next unless length $tok;
            next if $seen_inc{$tok}++;
            push @inc_parts, $tok;
        }
        print "Detected FreeType + HarfBuzz: enabling -DTKMT_HAVE_FREETYPE_HARFBUZZ=1\n";
    } else {
        print "FreeType + HarfBuzz not detected: using built-in fallback font rasterizer\n";
    }
}

# Extract rpath for non-system Tcl/Tk lib dirs (POSIX only; Win32 uses PATH/DLL search)
my @rpaths;
if (!$is_win32) {
    for my $spec ($tcl_libs, $tk_libs) {
        while ($spec =~ /-L(\S+)/g) {
            my $dir = $1;
            next if $dir eq '/usr/lib'
                 || $dir eq '/usr/lib64'
                 || $dir eq '/usr/lib/x86_64-linux-gnu'
                 || $dir eq '/usr/lib/aarch64-linux-gnu';
            push @rpaths, "-Wl,-rpath,$dir" unless grep { $_ eq "-Wl,-rpath,$dir" } @rpaths;
        }
    }
}

my $ALL_INC = join(' ', @inc_parts);

my @sys_libs;
if ($is_darwin) {
    push @sys_libs, '-lpthread', '-lm';
} elsif ($is_linux) {
    push @sys_libs, '-ldl', '-lpthread', '-lm';
} elsif ($is_win32) {
    if ($is_msvc) {
        push @sys_libs, 'user32.lib', 'gdi32.lib';
    } else {
        push @sys_libs, '-luser32', '-lgdi32', '-lm';
    }
} else {
    push @sys_libs, '-lpthread', '-lm';
}

my $WIN32_PERL_LIB = $is_win32 ? '$(PERL_ARCHIVE)' : '';

my $TCL_BRIDGE_LIBS = join(' ', grep { length } ($WIN32_PERL_LIB, $tcl_libs, $tk_libs, @rpaths, @sys_libs));

my @gfx_extra_libs;
if ($is_darwin) {
    push @gfx_extra_libs, '-framework Metal', '-framework QuartzCore', '-framework Cocoa';
}
my $GFX_LIBS = join(' ', grep { length } ($WIN32_PERL_LIB, $tcl_libs, $tk_libs, $ft_hb_libs, @gfx_extra_libs, @rpaths, @sys_libs));

my $DLEXT          = $Config{dlext}      || ($is_win32 ? 'dll' : 'so');
my $OBJ            = $Config{obj_ext}    || ($is_msvc ? '.obj' : '.o');
my $CFG_LD         = $Config{ld}         || $CFG_CC;
my $CFG_CCFLAGS    = $Config{ccflags}    // '';
my $CFG_OPTIMIZE   = $Config{optimize}   // ($is_msvc ? '/O2' : '-O2');
my $CFG_CCCDLFLAGS = $Config{cccdlflags} // ($is_linux ? '-fPIC' : '');
my $CFG_LDDLFLAGS  = $Config{lddlflags}  // ($is_darwin ? '-bundle -undefined dynamic_lookup' : ($is_msvc ? '/DLL' : '-shared'));

# Locate xsubpp & default typemap from active @INC (works for both installed and uninstalled perl5-mt)
my ($XSUBPP_BIN, $TYPEMAP_FILE);
for my $dir (@INC) {
    next if ref $dir;
    if (!$XSUBPP_BIN && -f "$dir/ExtUtils/xsubpp") {
        $XSUBPP_BIN = "$dir/ExtUtils/xsubpp";
    }
    if (!$TYPEMAP_FILE && -f "$dir/ExtUtils/typemap") {
        $TYPEMAP_FILE = "$dir/ExtUtils/typemap";
    }
}
die "Could not locate ExtUtils/xsubpp in \@INC\n" unless $XSUBPP_BIN;
my $TYPEMAP_ARG = $TYPEMAP_FILE ? "-typemap \"$TYPEMAP_FILE\"" : '';

my $TCL_MT_BUNDLE = "blib/arch/auto/Tcl/MT/MT.$DLEXT";
my $GFX_MT_BUNDLE = "blib/arch/auto/Tcl/Tk/MT/Gfx/Gfx.$DLEXT";

my @BRIDGE_OBJS = (
    "c/tcl_bridge/tcl_bridge$OBJ",
    "c/tcl_bridge/tk_surface$OBJ",
);

my @SCENE_OBJS = (
    "c/scene/scene$OBJ",
    "c/scene/tessellate$OBJ",
    "c/scene/atlas$OBJ",
);

my @GFX_OBJS = (
    "c/gfx/gfx_registry$OBJ",
    "c/gfx/gfx_software$OBJ",
    "c/gfx/gfx_vulkan$OBJ",
);
if ($is_darwin) {
    push @GFX_OBJS, "c/gfx/gfx_metal$OBJ";
}

print "Configuring Tcl::Tk::MT:\n";
print "  Tcl config : " . ($tcl_cfg_path // 'pkg-config/fallback') . " (version " . ($tcl_cfg{TCL_VERSION} // 'unknown') . ")\n";
print "  Tk  config : " . ($tk_cfg_path  // 'pkg-config/fallback') . " (version " . ($tk_cfg{TK_VERSION}  // 'unknown') . ")\n";
print "  Platform   : $^O (CC=$CFG_CC, DLEXT=$DLEXT)\n";

WriteMakefile(
    NAME             => 'Tcl::Tk::MT',
    VERSION_FROM     => 'lib/Tcl/MT.pm',
    ABSTRACT         => 'Tcl/Tk bridge with optional GPU canvas for perl5-mt and Perl 5',
    AUTHOR           => 'stratum42',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.016',
    XS               => {},
    C                => [],
    OBJECT           => '',
    clean            => {
        FILES => join(' ',
            'xs/TclMT.c', 'xs/TkMTGfx.c',
            "xs/TclMT$OBJ", "xs/TkMTGfx$OBJ",
            @BRIDGE_OBJS, @SCENE_OBJS, @GFX_OBJS,
            $TCL_MT_BUNDLE, $GFX_MT_BUNDLE,
        ),
    },
);

package MY;

sub dynamic {
    my $self = shift;
    my $base = $self->SUPER::dynamic(@_);
    return $base . "\n"
         . "dynamic :: $TCL_MT_BUNDLE $GFX_MT_BUNDLE\n"
         . "\t\$(NOECHO) \$(NOOP)\n";
}

sub postamble {
    my $self = shift;
    my $c11_std   = $is_msvc ? '/std:c11 /experimental:c11atomics /D_CRT_SECURE_NO_WARNINGS' : '-std=c11';
    my $c11_flags = join(' ', grep { length } ($c11_std, $ft_hb_defines));
    my $cc_c_flag = $is_msvc ? '/c' : '-c';
    my $obj_out   = $is_msvc ? '/Fo$@' : '-o $@';
    my $ld_out    = $is_msvc ? '/OUT:$@' : '-o $@';

    my $bridge_objs_str = join(' ', @BRIDGE_OBJS);
    my $scene_objs_str  = join(' ', @SCENE_OBJS);
    my $gfx_objs_str    = join(' ', @GFX_OBJS);

    my $rules = <<"EOF";

TKMT_INC = $ALL_INC
TKMT_C11 = $c11_flags
TKMT_CC  = $CFG_CC
TKMT_LD  = $CFG_LD
TKMT_CCFLAGS    = $CFG_CCFLAGS
TKMT_OPTIMIZE   = $CFG_OPTIMIZE
TKMT_CCCDLFLAGS = $CFG_CCCDLFLAGS
TKMT_LDDLFLAGS  = $CFG_LDDLFLAGS
TKMT_XSUBPP = \$(ABSPERLRUN) "$XSUBPP_BIN" $TYPEMAP_ARG
TKMT_CC_C11 = \$(TKMT_CC) $cc_c_flag \$(TKMT_INC) \$(TKMT_CCFLAGS) \$(TKMT_OPTIMIZE) \$(TKMT_CCCDLFLAGS) \$(TKMT_C11)
TKMT_CC_XS  = \$(TKMT_CC) $cc_c_flag \$(TKMT_INC) "-I\$(PERL_INC)" \$(TKMT_CCFLAGS) \$(TKMT_OPTIMIZE) \$(TKMT_CCCDLFLAGS) \$(TKMT_C11) -DVERSION=\\"\$(VERSION)\\" -DXS_VERSION=\\"\$(XS_VERSION)\\"

# ---- XS -> C rules ----
xs/TclMT.c : xs/TclMT.xs xs/mt_compat.h c/tcl_bridge/tcl_bridge.h c/tcl_bridge/tk_surface.h
\t\$(TKMT_XSUBPP) xs/TclMT.xs > xs/TclMT.xsc && \$(MV) xs/TclMT.xsc xs/TclMT.c

xs/TkMTGfx.c : xs/TkMTGfx.xs xs/mt_compat.h c/scene/scene.h c/gfx/tkmt_gfx.h c/tcl_bridge/tk_surface.h
\t\$(TKMT_XSUBPP) xs/TkMTGfx.xs > xs/TkMTGfx.xsc && \$(MV) xs/TkMTGfx.xsc xs/TkMTGfx.c

# ---- XS object compilation ----
xs/TclMT$OBJ : xs/TclMT.c
\t\$(TKMT_CC_XS) $obj_out xs/TclMT.c

xs/TkMTGfx$OBJ : xs/TkMTGfx.c
\t\$(TKMT_CC_XS) $obj_out xs/TkMTGfx.c

# ---- C11 library object compilation ----
c/tcl_bridge/tcl_bridge$OBJ : c/tcl_bridge/tcl_bridge.c c/tcl_bridge/tcl_bridge.h c/tcl_bridge/tcl_compat.h c/tkmt_thread.h
\t\$(TKMT_CC_C11) $obj_out c/tcl_bridge/tcl_bridge.c

c/tcl_bridge/tk_surface$OBJ : c/tcl_bridge/tk_surface.c c/tcl_bridge/tk_surface.h c/tcl_bridge/tcl_bridge.h c/tcl_bridge/tcl_compat.h
\t\$(TKMT_CC_C11) $obj_out c/tcl_bridge/tk_surface.c

c/scene/scene$OBJ : c/scene/scene.c c/scene/scene.h c/gfx/tkmt_gfx.h
\t\$(TKMT_CC_C11) $obj_out c/scene/scene.c

c/scene/tessellate$OBJ : c/scene/tessellate.c c/scene/scene.h c/gfx/tkmt_gfx.h
\t\$(TKMT_CC_C11) $obj_out c/scene/tessellate.c

c/scene/atlas$OBJ : c/scene/atlas.c c/scene/scene.h c/gfx/tkmt_gfx.h
\t\$(TKMT_CC_C11) $obj_out c/scene/atlas.c

c/gfx/gfx_registry$OBJ : c/gfx/gfx_registry.c c/gfx/tkmt_gfx.h c/tkmt_thread.h
\t\$(TKMT_CC_C11) $obj_out c/gfx/gfx_registry.c

c/gfx/gfx_software$OBJ : c/gfx/gfx_software.c c/gfx/tkmt_gfx.h
\t\$(TKMT_CC_C11) $obj_out c/gfx/gfx_software.c

c/gfx/gfx_vulkan$OBJ : c/gfx/gfx_vulkan.c c/gfx/tkmt_gfx.h
\t\$(TKMT_CC_C11) $obj_out c/gfx/gfx_vulkan.c
EOF

    if ($is_darwin) {
        $rules .= <<"EOF";

# ---- macOS Objective-C Metal backend (manual retain/release) ----
c/gfx/gfx_metal$OBJ : c/gfx/gfx_metal.m c/gfx/tkmt_gfx.h c/gfx/shaders/canvas2d.metal
\t\$(TKMT_CC) -c \$(TKMT_INC) \$(TKMT_CCFLAGS) \$(TKMT_OPTIMIZE) \$(TKMT_CCCDLFLAGS) -fno-objc-arc -o \$\@ c/gfx/gfx_metal.m
EOF
    }

    $rules .= <<"EOF";

# ---- Link Tcl::MT bundle ----
$TCL_MT_BUNDLE : xs/TclMT$OBJ $bridge_objs_str
\t\$(MKPATH) blib/arch/auto/Tcl/MT
\t\$(TKMT_LD) \$(TKMT_LDDLFLAGS) xs/TclMT$OBJ $bridge_objs_str $ld_out $TCL_BRIDGE_LIBS
\t\$(CHMOD) 755 \$\@

# ---- Link Tcl::Tk::MT::Gfx bundle ----
$GFX_MT_BUNDLE : xs/TkMTGfx$OBJ $bridge_objs_str $scene_objs_str $gfx_objs_str
\t\$(MKPATH) blib/arch/auto/Tcl/Tk/MT/Gfx
\t\$(TKMT_LD) \$(TKMT_LDDLFLAGS) xs/TkMTGfx$OBJ $bridge_objs_str $scene_objs_str $gfx_objs_str $ld_out $GFX_LIBS
\t\$(CHMOD) 755 \$\@
EOF

    return $rules;
}
