/*
 * xs/TkMTGfx.xs - Pure C11 Tier-1 Thread-Safe XS bindings for Tcl::Tk::MT::Gfx
 *
 * Exposes:
 *   - Graphics backend registry, probing, stats, SHA-256 readback helper
 *   - GPU/Software surface & RGBA8 texture management with zero-copy
 *     SVf_PACKED_AV (AV_PACKED_U8) fast path
 *   - Retained 2D scene graph (CRUD, batching, pan/zoom view matrix,
 *     create_lines_batch, create_instances, update_coords_packed, tags,
 *     spatial hit-testing, bbox, tessellation, render)
 */

#include "mt_compat.h"
#include "../c/gfx/tkmt_gfx.h"
#include "../c/scene/scene.h"
#include "../c/tcl_bridge/tk_surface.h"

#include <string.h>

#if defined(__APPLE__) && defined(__LP64__)
#  include <objc/runtime.h>
#  include <objc/message.h>
static double tkmt_cocoa_view_scale(void *nsview) {
    if (!nsview) return 1.0;
    id view = (id)nsview;
    SEL sel_win = sel_registerName("window");
    id (*msg_id)(id, SEL) = (id (*)(id, SEL))(void (*)(void))objc_msgSend;
    id win = msg_id(view, sel_win);
    if (!win) return 1.0;
    SEL sel_bsf = sel_registerName("backingScaleFactor");
#  if defined(__x86_64__)
    double (*msg_dbl)(id, SEL) = (double (*)(id, SEL))(void (*)(void))objc_msgSend_fpret;
#  else
    double (*msg_dbl)(id, SEL) = (double (*)(id, SEL))(void (*)(void))objc_msgSend;
#  endif
    double bsf = msg_dbl(win, sel_bsf);
    return (bsf >= 1.0 && bsf <= 8.0) ? bsf : 1.0;
}
#endif

static const char *tkmt_surface_platform_name(tkmt_surface_platform_t p) {
    switch (p) {
    case TKMT_SURFACE_COCOA: return "cocoa";
    case TKMT_SURFACE_X11:   return "x11";
    case TKMT_SURFACE_WIN32: return "win32";
    case TKMT_SURFACE_NONE:
    default:                 return "none";
    }
}

static tkmt_surface_geometry_fn tkmt_uv_to_geometry_fn(UV addr) {
    tkmt_surface_geometry_fn fn = NULL;
    if (addr != 0) {
        uintptr_t raw = (uintptr_t)addr;
        memcpy(&fn, &raw, sizeof(fn));
    }
    return fn;
}

static tkmt_surface_detach_fn tkmt_uv_to_detach_fn(UV addr) {
    tkmt_surface_detach_fn fn = NULL;
    if (addr != 0) {
        uintptr_t raw = (uintptr_t)addr;
        memcpy(&fn, &raw, sizeof(fn));
    }
    return fn;
}

/* -------------------------------------------------------------------------
 * Wrapper structs for Perl-blessed handles
 * ------------------------------------------------------------------------- */

#ifdef __APPLE__
extern void tkmt_metal_update_subview_rect(void *gfx_surf,
                                           int x, int y, int width, int height,
                                           int visible);
#endif

typedef struct tkmt_perl_surface {
    const tkmt_gfx_backend_t *backend;
    tkmt_gfx_surface_t       *surf;
    tkmt_surface_t           *tk_surf;
    uint32_t                  width;
    uint32_t                  height;
    float                     scale;
} tkmt_perl_surface_t;

#ifdef __APPLE__
static void tkmt_gfx_metal_geometry_cb(void *userdata,
                                       int x, int y, int width, int height,
                                       int visible) {
    tkmt_perl_surface_t *ps = (tkmt_perl_surface_t *)userdata;
    if (ps && ps->surf) {
        tkmt_metal_update_subview_rect(ps->surf, x, y, width, height, visible);
    }
}

static void tkmt_gfx_metal_detach_cb(void *userdata) {
    tkmt_perl_surface_t *ps = (tkmt_perl_surface_t *)userdata;
    if (ps) {
        ps->tk_surf = NULL;
    }
}
#endif

typedef struct tkmt_perl_scene {
    tkmt_scene_t *scene;
} tkmt_perl_scene_t;

static tkmt_perl_surface_t *sv_to_surface(pTHX_ SV *sv) {
    if (!sv || !SvROK(sv)) croak("Expected Tcl::Tk::MT::Gfx::Surface object");
    IV iv = SvIV(SvRV(sv));
    if (!iv) croak("Surface handle has been destroyed");
    return INT2PTR(tkmt_perl_surface_t *, iv);
}

static tkmt_perl_scene_t *sv_to_scene(pTHX_ SV *sv) {
    if (!sv || !SvROK(sv)) croak("Expected Tcl::Tk::MT::Gfx::Scene object");
    IV iv = SvIV(SvRV(sv));
    if (!iv) croak("Scene handle has been destroyed");
    return INT2PTR(tkmt_perl_scene_t *, iv);
}

/* -------------------------------------------------------------------------
 * String/enum parsing helpers
 * ------------------------------------------------------------------------- */

static tkmt_item_type_t parse_item_type(pTHX_ SV *sv) {
    if (SvIOK(sv)) {
        return (tkmt_item_type_t)SvIV(sv);
    }
    const char *s = SvPV_nolen(sv);
    if (strcmp(s, "line") == 0)           return TKMT_ITEM_LINE;
    if (strcmp(s, "rectangle") == 0)      return TKMT_ITEM_RECTANGLE;
    if (strcmp(s, "rect") == 0)           return TKMT_ITEM_RECTANGLE;
    if (strcmp(s, "oval") == 0)           return TKMT_ITEM_OVAL;
    if (strcmp(s, "arc") == 0)            return TKMT_ITEM_ARC;
    if (strcmp(s, "polygon") == 0)        return TKMT_ITEM_POLYGON;
    if (strcmp(s, "poly") == 0)           return TKMT_ITEM_POLYGON;
    if (strcmp(s, "text") == 0)           return TKMT_ITEM_TEXT;
    if (strcmp(s, "image") == 0)          return TKMT_ITEM_IMAGE;
    if (strcmp(s, "window") == 0)         return TKMT_ITEM_WINDOW;
    if (strcmp(s, "instance_batch") == 0) return TKMT_ITEM_INSTANCE_BATCH;
    return TKMT_ITEM_NONE;
}

static tkmt_anchor_t parse_anchor(pTHX_ SV *sv) {
    if (SvIOK(sv)) return (tkmt_anchor_t)SvIV(sv);
    const char *s = SvPV_nolen(sv);
    if (strcmp(s, "nw") == 0)     return TKMT_ANCHOR_NW;
    if (strcmp(s, "n") == 0)      return TKMT_ANCHOR_N;
    if (strcmp(s, "ne") == 0)     return TKMT_ANCHOR_NE;
    if (strcmp(s, "w") == 0)      return TKMT_ANCHOR_W;
    if (strcmp(s, "e") == 0)      return TKMT_ANCHOR_E;
    if (strcmp(s, "sw") == 0)     return TKMT_ANCHOR_SW;
    if (strcmp(s, "s") == 0)      return TKMT_ANCHOR_S;
    if (strcmp(s, "se") == 0)     return TKMT_ANCHOR_SE;
    return TKMT_ANCHOR_CENTER;
}

static tkmt_item_state_t parse_state(pTHX_ SV *sv) {
    if (SvIOK(sv)) return (tkmt_item_state_t)SvIV(sv);
    const char *s = SvPV_nolen(sv);
    if (strcmp(s, "hidden") == 0)   return TKMT_STATE_HIDDEN;
    if (strcmp(s, "disabled") == 0) return TKMT_STATE_DISABLED;
    return TKMT_STATE_NORMAL;
}

static tkmt_arc_style_t parse_arc_style(pTHX_ SV *sv) {
    if (!sv || !SvOK(sv)) return TKMT_ARC_PIESLICE;
    if (SvIOK(sv)) return (tkmt_arc_style_t)SvIV(sv);
    const char *s = SvPV_nolen(sv);
    if (strcmp(s, "chord") == 0) return TKMT_ARC_CHORD;
    if (strcmp(s, "arc") == 0)   return TKMT_ARC_ARC;
    return TKMT_ARC_PIESLICE;
}

static tkmt_cap_style_t parse_cap_style(pTHX_ SV *sv) {
    if (!sv || !SvOK(sv)) return TKMT_CAP_BUTT;
    if (SvIOK(sv)) return (tkmt_cap_style_t)SvIV(sv);
    const char *s = SvPV_nolen(sv);
    if (strcmp(s, "round") == 0)      return TKMT_CAP_ROUND;
    if (strcmp(s, "projecting") == 0) return TKMT_CAP_PROJECTING;
    return TKMT_CAP_BUTT;
}

static tkmt_join_style_t parse_join_style(pTHX_ SV *sv) {
    if (!sv || !SvOK(sv)) return TKMT_JOIN_MITER;
    if (SvIOK(sv)) return (tkmt_join_style_t)SvIV(sv);
    const char *s = SvPV_nolen(sv);
    if (strcmp(s, "round") == 0) return TKMT_JOIN_ROUND;
    if (strcmp(s, "bevel") == 0) return TKMT_JOIN_BEVEL;
    return TKMT_JOIN_MITER;
}

/* Read pixel bytes from either a Perl byte string SV or an arrayref (with
 * zero-copy SVf_PACKED_AV AV_PACKED_U8 fast path). */
static int read_u8_pixels(pTHX_ SV *sv, const uint8_t **out_buf, size_t *out_len, int *out_owned) {
    *out_buf   = NULL;
    *out_len   = 0;
    *out_owned = 0;

    if (!sv || !SvOK(sv)) return 1;

    if (SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV) {
        AV *av = (AV *)SvRV(sv);
        return tkmt_av_read_u8(aTHX_ av, out_buf, out_len, out_owned);
    }

    STRLEN len = 0;
    const char *pv = SvPVbyte(sv, len);
    *out_buf   = (const uint8_t *)pv;
    *out_len   = (size_t)len;
    *out_owned = 0;
    return 1;
}

static HV *backend_to_hv(pTHX_ const tkmt_gfx_backend_t *b) {
    HV *hv = newHV();
    (void)hv_stores(hv, "id",           newSViv((IV)b->id));
    (void)hv_stores(hv, "name",         newSVpv(b->name ? b->name : "", 0));
    (void)hv_stores(hv, "description",  newSVpv(b->description ? b->description : "", 0));
    (void)hv_stores(hv, "device_class", newSVpv(b->device_class == TKMT_GFX_DEV_GPU ? "gpu" : "cpu", 0));
    (void)hv_stores(hv, "priority",     newSViv((IV)b->priority));
    (void)hv_stores(hv, "caps",         newSVuv((UV)b->caps));
    (void)hv_stores(hv, "available",    newSViv(b->probe ? b->probe() : 1));
    return hv;
}

static AV *ids_to_av(pTHX_ const uint32_t *ids, uint32_t count) {
    AV *av = newAV();
    if (count > 0) av_extend(av, (SSize_t)count - 1);
    for (uint32_t i = 0; i < count; i++) {
        av_push(av, newSVuv((UV)ids[i]));
    }
    return av;
}

/* ========================================================================= */

MODULE = Tcl::Tk::MT::Gfx   PACKAGE = Tcl::Tk::MT::Gfx

PROTOTYPES: DISABLE

int
init()
    CODE:
        RETVAL = tkmt_gfx_init();
    OUTPUT:
        RETVAL

void
shutdown()
    CODE:
        tkmt_gfx_shutdown();

SV *
active_backend()
    CODE:
        const tkmt_gfx_backend_t *b = tkmt_gfx_active();
        if (b && b->name) {
            RETVAL = newSVpv(b->name, 0);
        } else {
            RETVAL = &PL_sv_undef;
        }
    OUTPUT:
        RETVAL

SV *
active_backend_info()
    CODE:
        const tkmt_gfx_backend_t *b = tkmt_gfx_active();
        if (b) {
            RETVAL = newRV_noinc((SV *)backend_to_hv(aTHX_ b));
        } else {
            RETVAL = &PL_sv_undef;
        }
    OUTPUT:
        RETVAL

SV *
list_backends()
    CODE:
        const tkmt_gfx_backend_t *arr[TKMT_GFX_BACKEND_MAX + 4];
        size_t n = tkmt_gfx_list(arr, TKMT_GFX_BACKEND_MAX + 4);
        AV *av = newAV();
        for (size_t i = 0; i < n; i++) {
            av_push(av, newRV_noinc((SV *)backend_to_hv(aTHX_ arr[i])));
        }
        RETVAL = newRV_noinc((SV *)av);
    OUTPUT:
        RETVAL

int
backend_available(name)
        const char *name
    CODE:
        RETVAL = tkmt_gfx_backend_available(name);
    OUTPUT:
        RETVAL

int
is_enabled()
    CODE:
        RETVAL = tkmt_gfx_is_enabled();
    OUTPUT:
        RETVAL

SV *
stats()
    CODE:
        tkmt_gfx_stats_t st;
        tkmt_gfx_get_stats(&st);
        HV *hv = newHV();
        (void)hv_stores(hv, "frames_rendered",     newSVuv((UV)st.frames_rendered));
        (void)hv_stores(hv, "draw_calls",          newSVuv((UV)st.draw_calls));
        (void)hv_stores(hv, "vertices_submitted",  newSVuv((UV)st.vertices_submitted));
        (void)hv_stores(hv, "instances_submitted", newSVuv((UV)st.instances_submitted));
        (void)hv_stores(hv, "offload_calls",       newSVuv((UV)st.offload_calls));
        (void)hv_stores(hv, "fallback_calls",      newSVuv((UV)st.fallback_calls));
        (void)hv_stores(hv, "readback_calls",      newSVuv((UV)st.readback_calls));
        (void)hv_stores(hv, "last_backend_name",
                        st.last_backend_name ? newSVpv(st.last_backend_name, 0) : newSVpvs(""));
        RETVAL = newRV_noinc((SV *)hv);
    OUTPUT:
        RETVAL

void
reset_stats()
    CODE:
        tkmt_gfx_reset_stats();

void
reset_for_test(mode_sv = &PL_sv_undef)
        SV *mode_sv
    CODE:
        const char *mode = (mode_sv && SvOK(mode_sv)) ? SvPV_nolen(mode_sv) : NULL;
        tkmt_gfx_reset_for_test(mode);

UV
rgba(r, g, b, a = 255)
        unsigned int r
        unsigned int g
        unsigned int b
        unsigned int a
    CODE:
        RETVAL = (UV)tkmt_rgba((uint8_t)r, (uint8_t)g, (uint8_t)b, (uint8_t)a);
    OUTPUT:
        RETVAL

SV *
sha256_hex(data_sv)
        SV *data_sv
    CODE:
        STRLEN len = 0;
        const char *buf = SvPVbyte(data_sv, len);
        char hex[65];
        tkmt_gfx_sha256_hex((const uint8_t *)buf, (size_t)len, hex);
        RETVAL = newSVpvn(hex, 64);
    OUTPUT:
        RETVAL

int
is_perl5_mt()
    CODE:
        RETVAL = TKMT_IS_PERL5_MT;
    OUTPUT:
        RETVAL

int
have_packed_av()
    CODE:
        RETVAL = TKMT_HAVE_PACKED_AV;
    OUTPUT:
        RETVAL

int
av_packed_type(aref)
        SV *aref
    CODE:
        if (!SvROK(aref) || SvTYPE(SvRV(aref)) != SVt_PVAV) {
            RETVAL = AV_PACKED_NONE;
        } else {
            AV *av = (AV *)SvRV(aref);
            RETVAL = (int)AvPACKED_TYPE(av);
        }
    OUTPUT:
        RETVAL

SV *
create_surface(width, height, backend_sv = &PL_sv_undef, scale = 1.0, headless = 1, native_surface_ptr = 0)
        UV width
        UV height
        SV *backend_sv
        double scale
        int headless
        UV native_surface_ptr
    CODE:
        tkmt_gfx_init();
        const tkmt_gfx_backend_t *b = NULL;
        if (backend_sv && SvOK(backend_sv)) {
            const char *bname = SvPV_nolen(backend_sv);
            b = tkmt_gfx_find(bname);
            if (!b) croak("Unknown gfx backend: %s", bname);
            if (b->init) (void)b->init();
        } else {
            b = tkmt_gfx_active();
        }
        if (!b) {
            RETVAL = &PL_sv_undef;
        } else {
            tkmt_surface_desc_t desc;
            memset(&desc, 0, sizeof(desc));
            desc.width       = (uint32_t)width;
            desc.height      = (uint32_t)height;
            desc.scale       = (scale > 0.0) ? (float)scale : 1.0f;
            desc.handle_type = TKMT_NATIVE_NONE;
            desc.headless    = headless ? 1 : 0;

            tkmt_surface_t *tks = NULL;
            if (native_surface_ptr != 0) {
                tks = INT2PTR(tkmt_surface_t *, native_surface_ptr);
                tkmt_native_surface_t ns;
                memset(&ns, 0, sizeof(ns));
                if (tkmt_surface_get_native(tks, &ns)) {
                    if (ns.platform == TKMT_SURFACE_COCOA) {
                        desc.handle_type   = TKMT_NATIVE_NSVIEW;
                        desc.native_window = (uintptr_t)ns.view;
                        desc.headless      = 0;
                    } else if (ns.platform == TKMT_SURFACE_X11) {
                        desc.handle_type    = TKMT_NATIVE_X11;
                        desc.native_display = ns.display;
                        desc.native_window  = ns.window;
                        desc.headless       = 0;
                    } else if (ns.platform == TKMT_SURFACE_WIN32) {
                        desc.handle_type   = TKMT_NATIVE_WIN32;
                        desc.native_window = ns.window;
                        desc.headless      = 0;
                    }
                    if (desc.width == 0 && ns.width > 0)   desc.width  = (uint32_t)ns.width;
                    if (desc.height == 0 && ns.height > 0) desc.height = (uint32_t)ns.height;
                    if (ns.scale > 0.0f)                   desc.scale  = ns.scale;
                }
            }

            tkmt_gfx_surface_t *gs = b->create_surface(&desc);
            if (!gs) {
                RETVAL = &PL_sv_undef;
            } else {
                tkmt_perl_surface_t *ps = (tkmt_perl_surface_t *)calloc(1, sizeof(*ps));
                ps->backend = b;
                ps->surf    = gs;
                ps->width   = desc.width;
                ps->height  = desc.height;
                ps->scale   = desc.scale;
#ifdef __APPLE__
                if (tks && !desc.headless && b->id == TKMT_GFX_BACKEND_METAL) {
                    ps->tk_surf = tks;
                    tkmt_surface_set_geometry_cb(
                        tks, ps, tkmt_gfx_metal_geometry_cb, tkmt_gfx_metal_detach_cb
                    );
                }
#else
                (void)tks;
#endif
                RETVAL = sv_setref_pv(newSV(0), "Tcl::Tk::MT::Gfx::Surface", ps);
            }
        }
    OUTPUT:
        RETVAL

SV *
create_scene(width = 640, height = 480)
        UV width
        UV height
    CODE:
        tkmt_scene_t *sc = tkmt_scene_create((uint32_t)width, (uint32_t)height);
        if (!sc) croak("Failed to create tkmt_scene");
        tkmt_perl_scene_t *ps = (tkmt_perl_scene_t *)calloc(1, sizeof(*ps));
        ps->scene = sc;
        RETVAL = sv_setref_pv(newSV(0), "Tcl::Tk::MT::Gfx::Scene", ps);
    OUTPUT:
        RETVAL

# =========================================================================

MODULE = Tcl::Tk::MT::Gfx   PACKAGE = Tcl::Tk::MT::Gfx::Surface

PROTOTYPES: DISABLE

void
DESTROY(self)
        SV *self
    CODE:
        if (SvROK(self)) {
            IV iv = SvIV(SvRV(self));
            if (iv) {
                tkmt_perl_surface_t *ps = INT2PTR(tkmt_perl_surface_t *, iv);
                if (ps->tk_surf) {
                    tkmt_surface_set_geometry_cb(ps->tk_surf, NULL, NULL, NULL);
                    ps->tk_surf = NULL;
                }
                if (ps->backend && ps->backend->destroy_surface && ps->surf) {
                    ps->backend->destroy_surface(ps->surf);
                }
                free(ps);
                sv_setiv(SvRV(self), 0);
            }
        }

const char *
backend_name(self)
        SV *self
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        RETVAL = (ps->backend && ps->backend->name) ? ps->backend->name : "";
    OUTPUT:
        RETVAL

UV
width(self)
        SV *self
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        RETVAL = ps->width;
    OUTPUT:
        RETVAL

UV
height(self)
        SV *self
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        RETVAL = ps->height;
    OUTPUT:
        RETVAL

double
scale(self)
        SV *self
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        RETVAL = (double)ps->scale;
    OUTPUT:
        RETVAL

int
resize(self, w, h, scale = 1.0)
        SV *self
        UV w
        UV h
        double scale
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        RETVAL = ps->backend->resize_surface(ps->surf, (uint32_t)w, (uint32_t)h, (float)scale);
        if (RETVAL == 0) {
            ps->width  = (uint32_t)w;
            ps->height = (uint32_t)h;
            ps->scale  = (float)scale;
        }
    OUTPUT:
        RETVAL

UV
texture_create_rgba(self, w, h, pixels_sv)
        SV *self
        UV w
        UV h
        SV *pixels_sv
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        const uint8_t *buf = NULL;
        size_t len = 0;
        int owned = 0;
        if (!read_u8_pixels(aTHX_ pixels_sv, &buf, &len, &owned)) {
            croak("Out of memory reading RGBA pixels");
        }
        size_t need = (size_t)w * (size_t)h * 4u;
        if (buf && len < need) {
            if (owned) free((void *)buf);
            croak("RGBA buffer too small: got %zu, need %zu", len, need);
        }
        tkmt_tex_id_t tid = ps->backend->texture_create(ps->surf, (uint32_t)w, (uint32_t)h,
                                                        TKMT_TEX_RGBA8, buf);
        if (owned) free((void *)buf);
        RETVAL = (UV)tid;
    OUTPUT:
        RETVAL

int
texture_update_rgba(self, tex_id, x, y, w, h, pixels_sv)
        SV *self
        UV tex_id
        UV x
        UV y
        UV w
        UV h
        SV *pixels_sv
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        const uint8_t *buf = NULL;
        size_t len = 0;
        int owned = 0;
        if (!read_u8_pixels(aTHX_ pixels_sv, &buf, &len, &owned)) {
            croak("Out of memory reading RGBA pixels");
        }
        size_t need = (size_t)w * (size_t)h * 4u;
        if (!buf || len < need) {
            if (owned) free((void *)buf);
            croak("RGBA buffer too small: got %zu, need %zu", len, need);
        }
        RETVAL = ps->backend->texture_update(ps->surf, (tkmt_tex_id_t)tex_id,
                                             (uint32_t)x, (uint32_t)y,
                                             (uint32_t)w, (uint32_t)h, buf);
        if (owned) free((void *)buf);
    OUTPUT:
        RETVAL

UV
put_rgba_packed(self, tex_id, w, h, pixels_sv)
        SV *self
        UV tex_id
        UV w
        UV h
        SV *pixels_sv
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        const uint8_t *buf = NULL;
        size_t len = 0;
        int owned = 0;
        if (!read_u8_pixels(aTHX_ pixels_sv, &buf, &len, &owned)) {
            croak("Out of memory reading packed RGBA pixels");
        }
        size_t need = (size_t)w * (size_t)h * 4u;
        if (!buf || len < need) {
            if (owned) free((void *)buf);
            croak("put_rgba_packed: buffer too small (%zu < %zu)", len, need);
        }
        tkmt_tex_id_t tid = (tkmt_tex_id_t)tex_id;
        if (tid == 0) {
            tid = ps->backend->texture_create(ps->surf, (uint32_t)w, (uint32_t)h,
                                              TKMT_TEX_RGBA8, buf);
        } else {
            (void)ps->backend->texture_update(ps->surf, tid, 0, 0,
                                              (uint32_t)w, (uint32_t)h, buf);
        }
        if (owned) free((void *)buf);
        RETVAL = (UV)tid;
    OUTPUT:
        RETVAL

void
texture_destroy(self, tex_id)
        SV *self
        UV tex_id
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        if (ps->backend->texture_destroy) {
            ps->backend->texture_destroy(ps->surf, (tkmt_tex_id_t)tex_id);
        }

SV *
readback_rgba(self)
        SV *self
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        size_t nbytes = (size_t)ps->width * (size_t)ps->height * 4u;
        SV *sv = newSV(nbytes ? nbytes : 1);
        SvPOK_only(sv);
        uint8_t *dst = (uint8_t *)SvPVX(sv);
        int rc = ps->backend->readback_rgba(ps->surf, dst, nbytes);
        if (rc != 0) {
            SvREFCNT_dec(sv);
            RETVAL = &PL_sv_undef;
        } else {
            SvCUR_set(sv, nbytes);
            dst[nbytes] = '\0';
            RETVAL = sv;
        }
    OUTPUT:
        RETVAL

SV *
readback_sha256(self)
        SV *self
    CODE:
        tkmt_perl_surface_t *ps = sv_to_surface(aTHX_ self);
        size_t nbytes = (size_t)ps->width * (size_t)ps->height * 4u;
        uint8_t *buf = (uint8_t *)malloc(nbytes ? nbytes : 1);
        if (!buf) croak("Out of memory in readback_sha256");
        int rc = ps->backend->readback_rgba(ps->surf, buf, nbytes);
        if (rc != 0) {
            free(buf);
            RETVAL = &PL_sv_undef;
        } else {
            char hex[65];
            tkmt_gfx_sha256_hex(buf, nbytes, hex);
            free(buf);
            RETVAL = newSVpvn(hex, 64);
        }
    OUTPUT:
        RETVAL

# =========================================================================

MODULE = Tcl::Tk::MT::Gfx   PACKAGE = Tcl::Tk::MT::Gfx::Scene

PROTOTYPES: DISABLE

void
DESTROY(self)
        SV *self
    CODE:
        if (SvROK(self)) {
            IV iv = SvIV(SvRV(self));
            if (iv) {
                tkmt_perl_scene_t *ps = INT2PTR(tkmt_perl_scene_t *, iv);
                if (ps->scene) tkmt_scene_destroy(ps->scene);
                free(ps);
                sv_setiv(SvRV(self), 0);
            }
        }

void
set_viewport(self, w, h)
        SV *self
        UV w
        UV h
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_scene_set_viewport(ps->scene, (uint32_t)w, (uint32_t)h);

void
set_clear_color(self, rgba, do_clear = 1)
        SV *self
        UV rgba
        int do_clear
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_scene_set_clear_color(ps->scene, (uint32_t)rgba, do_clear);

void
batch_begin(self)
        SV *self
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_scene_batch_begin(ps->scene);

void
batch_end(self)
        SV *self
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_scene_batch_end(ps->scene);

int
batch_depth(self)
        SV *self
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_batch_depth(ps->scene);
    OUTPUT:
        RETVAL

void
set_view_matrix(self, mat_aref)
        SV *self
        SV *mat_aref
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        if (!SvROK(mat_aref) || SvTYPE(SvRV(mat_aref)) != SVt_PVAV) {
            croak("set_view_matrix expects arrayref of 9 floats");
        }
        float *buf = NULL;
        size_t len = 0;
        int owned = 0;
        if (!tkmt_av_read_f32(aTHX_ (AV *)SvRV(mat_aref), &buf, &len, &owned) || len < 9) {
            if (owned) free(buf);
            croak("set_view_matrix requires 9 elements");
        }
        tkmt_scene_set_view_matrix(ps->scene, buf);
        if (owned) free(buf);

SV *
get_view_matrix(self)
        SV *self
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        float m[9];
        tkmt_scene_get_view_matrix(ps->scene, m);
        AV *av = newAV();
        av_extend(av, 8);
        for (int i = 0; i < 9; i++) {
            av_push(av, newSVnv((NV)m[i]));
        }
        RETVAL = newRV_noinc((SV *)av);
    OUTPUT:
        RETVAL

void
set_pan_zoom(self, tx, ty, sx, sy)
        SV *self
        double tx
        double ty
        double sx
        double sy
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_scene_set_pan_zoom(ps->scene, (float)tx, (float)ty, (float)sx, (float)sy);

void
pan(self, dx, dy)
        SV *self
        double dx
        double dy
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_scene_pan(ps->scene, (float)dx, (float)dy);

void
zoom(self, factor, cx = 0.0, cy = 0.0)
        SV *self
        double factor
        double cx
        double cy
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_scene_zoom(ps->scene, (float)factor, (float)cx, (float)cy);

UV
create_item(self, type_sv, coords_aref = &PL_sv_undef)
        SV *self
        SV *type_sv
        SV *coords_aref
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_item_type_t type = parse_item_type(aTHX_ type_sv);
        if (type == TKMT_ITEM_NONE) croak("Invalid item type");

        float *coords = NULL;
        size_t len = 0;
        int owned = 0;
        if (coords_aref && SvROK(coords_aref) && SvTYPE(SvRV(coords_aref)) == SVt_PVAV) {
            if (!tkmt_av_read_f32(aTHX_ (AV *)SvRV(coords_aref), &coords, &len, &owned)) {
                croak("Out of memory reading coords");
            }
        }
        uint32_t id = tkmt_scene_create_item(ps->scene, type, coords, (uint32_t)len);
        if (owned) free(coords);
        RETVAL = (UV)id;
    OUTPUT:
        RETVAL

UV
create_lines_batch(self, coords_aref, color = 0xFF000000, width = 1.0)
        SV *self
        SV *coords_aref
        UV color
        double width
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        if (!SvROK(coords_aref) || SvTYPE(SvRV(coords_aref)) != SVt_PVAV) {
            croak("create_lines_batch expects arrayref");
        }
        float *coords = NULL;
        size_t len = 0;
        int owned = 0;
        if (!tkmt_av_read_f32(aTHX_ (AV *)SvRV(coords_aref), &coords, &len, &owned)) {
            croak("Out of memory reading line batch coords");
        }
        uint32_t segs = (uint32_t)(len / 4u);
        uint32_t created = tkmt_scene_create_lines_batch(
            ps->scene, coords, segs, (uint32_t)color, (float)width, NULL);
        if (owned) free(coords);
        RETVAL = (UV)created;
    OUTPUT:
        RETVAL

UV
create_instances(self, data_aref, shape = 2, flags = 1, stride = 4)
        SV *self
        SV *data_aref
        UV shape
        UV flags
        UV stride
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        if (!SvROK(data_aref) || SvTYPE(SvRV(data_aref)) != SVt_PVAV) {
            croak("create_instances expects arrayref");
        }
        const double *buf = NULL;
        size_t len = 0;
        int owned = 0;
        if (!tkmt_av_read_nv(aTHX_ (AV *)SvRV(data_aref), &buf, &len, &owned)) {
            croak("Out of memory reading instance data");
        }
        if (stride < 4) stride = 4;
        uint32_t count = (uint32_t)(len / stride);
        tkmt_instance_t *insts = NULL;
        if (count > 0) {
            insts = (tkmt_instance_t *)calloc(count, sizeof(tkmt_instance_t));
            if (!insts) {
                if (owned) free((void *)buf);
                croak("Out of memory allocating instances");
            }
            for (uint32_t i = 0; i < count; i++) {
                const double *p = buf + (size_t)i * stride;
                tkmt_instance_t *dst = &insts[i];
                if (stride == 4) {
                    /* [x, y, rgba_u32, size] centered at (x, y) */
                    float sz = (float)p[3];
                    dst->x            = (float)p[0] - sz * 0.5f;
                    dst->y            = (float)p[1] - sz * 0.5f;
                    dst->w            = sz;
                    dst->h            = sz;
                    dst->fill_color   = (uint32_t)(uint64_t)p[2];
                    dst->stroke_color = 0;
                    dst->stroke_width = 0.0f;
                } else if (stride == 5) {
                    /* [x, y, w, h, fill_rgba] */
                    dst->x            = (float)p[0];
                    dst->y            = (float)p[1];
                    dst->w            = (float)p[2];
                    dst->h            = (float)p[3];
                    dst->fill_color   = (uint32_t)(uint64_t)p[4];
                    dst->stroke_color = 0;
                    dst->stroke_width = 0.0f;
                } else {
                    /* [x, y, w, h, fill_rgba, stroke_rgba, ...] */
                    dst->x            = (float)p[0];
                    dst->y            = (float)p[1];
                    dst->w            = (float)p[2];
                    dst->h            = (float)p[3];
                    dst->fill_color   = (uint32_t)(uint64_t)p[4];
                    dst->stroke_color = (uint32_t)(uint64_t)p[5];
                    dst->stroke_width = (stride >= 7) ? (float)p[6] : 1.0f;
                }
                dst->shape = (uint32_t)shape;
                dst->flags = (uint32_t)flags;
            }
        }
        uint32_t id = tkmt_scene_create_instances(ps->scene, insts, count);
        free(insts);
        if (owned) free((void *)buf);
        RETVAL = (UV)id;
    OUTPUT:
        RETVAL

int
update_coords_packed(self, id, coords_aref)
        SV *self
        UV id
        SV *coords_aref
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        if (!SvROK(coords_aref) || SvTYPE(SvRV(coords_aref)) != SVt_PVAV) {
            croak("update_coords_packed expects arrayref");
        }
        const double *buf = NULL;
        size_t len = 0;
        int owned = 0;
        if (!tkmt_av_read_nv(aTHX_ (AV *)SvRV(coords_aref), &buf, &len, &owned)) {
            croak("Out of memory reading packed coords");
        }
        RETVAL = tkmt_scene_set_coords_double(ps->scene, (uint32_t)id, buf, (uint32_t)len);
        if (owned) free((void *)buf);
    OUTPUT:
        RETVAL

SV *
get_coords(self, id)
        SV *self
        UV id
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        const tkmt_scene_item_t *it = tkmt_scene_get_item_const(ps->scene, (uint32_t)id);
        if (!it) {
            RETVAL = &PL_sv_undef;
        } else {
            AV *av = newAV();
            if (it->coord_count > 0) av_extend(av, (SSize_t)it->coord_count - 1);
            for (uint32_t i = 0; i < it->coord_count; i++) {
                av_push(av, newSVnv((NV)it->coords[i]));
            }
            RETVAL = newRV_noinc((SV *)av);
        }
    OUTPUT:
        RETVAL

int
set_fill(self, id, rgba)
        SV *self
        UV id
        UV rgba
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_set_fill(ps->scene, (uint32_t)id, (uint32_t)rgba);
    OUTPUT:
        RETVAL

int
set_outline(self, id, rgba)
        SV *self
        UV id
        UV rgba
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_set_outline(ps->scene, (uint32_t)id, (uint32_t)rgba);
    OUTPUT:
        RETVAL

int
set_width(self, id, width)
        SV *self
        UV id
        double width
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_set_width(ps->scene, (uint32_t)id, (float)width);
    OUTPUT:
        RETVAL

int
set_corner_radius(self, id, radius)
        SV *self
        UV id
        double radius
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_set_corner_radius(ps->scene, (uint32_t)id, (float)radius);
    OUTPUT:
        RETVAL

int
set_arc_angles(self, id, start_deg, extent_deg, style_sv = &PL_sv_undef)
        SV *self
        UV id
        double start_deg
        double extent_deg
        SV *style_sv
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_arc_style_t st = parse_arc_style(aTHX_ style_sv);
        RETVAL = tkmt_scene_set_arc_angles(ps->scene, (uint32_t)id,
                                           (float)start_deg, (float)extent_deg, st);
    OUTPUT:
        RETVAL

int
set_line_style(self, id, cap_sv = &PL_sv_undef, join_sv = &PL_sv_undef, dash_aref = &PL_sv_undef, dash_offset = 0.0)
        SV *self
        UV id
        SV *cap_sv
        SV *join_sv
        SV *dash_aref
        double dash_offset
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_cap_style_t cap   = parse_cap_style(aTHX_ cap_sv);
        tkmt_join_style_t join = parse_join_style(aTHX_ join_sv);
        float dash[TKMT_MAX_DASH];
        uint8_t dcount = 0;
        if (dash_aref && SvROK(dash_aref) && SvTYPE(SvRV(dash_aref)) == SVt_PVAV) {
            float *dbuf = NULL;
            size_t dlen = 0;
            int owned = 0;
            if (tkmt_av_read_f32(aTHX_ (AV *)SvRV(dash_aref), &dbuf, &dlen, &owned)) {
                if (dlen > TKMT_MAX_DASH) dlen = TKMT_MAX_DASH;
                if (dlen > 0) memcpy(dash, dbuf, dlen * sizeof(float));
                dcount = (uint8_t)dlen;
                if (owned) free(dbuf);
            }
        }
        RETVAL = tkmt_scene_set_line_style(ps->scene, (uint32_t)id, cap, join,
                                           dcount ? dash : NULL, dcount, (float)dash_offset);
    OUTPUT:
        RETVAL

int
set_state(self, id, state_sv)
        SV *self
        UV id
        SV *state_sv
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_set_state(ps->scene, (uint32_t)id, parse_state(aTHX_ state_sv));
    OUTPUT:
        RETVAL

int
set_flags(self, id, flags)
        SV *self
        UV id
        UV flags
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_set_flags(ps->scene, (uint32_t)id, (uint32_t)flags);
    OUTPUT:
        RETVAL

int
set_anchor(self, id, anchor_sv)
        SV *self
        UV id
        SV *anchor_sv
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_set_anchor(ps->scene, (uint32_t)id, parse_anchor(aTHX_ anchor_sv));
    OUTPUT:
        RETVAL

int
set_text(self, id, text, font_sv = &PL_sv_undef, font_size = 12.0)
        SV *self
        UV id
        const char *text
        SV *font_sv
        double font_size
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        const char *ff = (font_sv && SvOK(font_sv)) ? SvPV_nolen(font_sv) : NULL;
        RETVAL = tkmt_scene_set_text(ps->scene, (uint32_t)id, text, ff, (float)font_size);
    OUTPUT:
        RETVAL

int
set_image(self, id, tex_id, w, h)
        SV *self
        UV id
        UV tex_id
        UV w
        UV h
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_set_image(ps->scene, (uint32_t)id, (tkmt_tex_id_t)tex_id,
                                      (uint32_t)w, (uint32_t)h);
    OUTPUT:
        RETVAL

int
set_window(self, id, path, w, h)
        SV *self
        UV id
        const char *path
        double w
        double h
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_set_window(ps->scene, (uint32_t)id, path, (float)w, (float)h);
    OUTPUT:
        RETVAL

int
delete_item(self, id)
        SV *self
        UV id
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_delete_item(ps->scene, (uint32_t)id);
    OUTPUT:
        RETVAL

UV
delete_by_tag(self, tag_or_id)
        SV *self
        const char *tag_or_id
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = (UV)tkmt_scene_delete_by_tag(ps->scene, tag_or_id);
    OUTPUT:
        RETVAL

void
clear(self)
        SV *self
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_scene_clear(ps->scene);

int
move(self, tag_or_id, dx, dy)
        SV *self
        const char *tag_or_id
        double dx
        double dy
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_move(ps->scene, tag_or_id, (float)dx, (float)dy);
    OUTPUT:
        RETVAL

int
scale(self, tag_or_id, ox, oy, sx, sy)
        SV *self
        const char *tag_or_id
        double ox
        double oy
        double sx
        double sy
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_scale(ps->scene, tag_or_id,
                                  (float)ox, (float)oy, (float)sx, (float)sy);
    OUTPUT:
        RETVAL

int
raise(self, id, above_id = 0)
        SV *self
        UV id
        UV above_id
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_raise(ps->scene, (uint32_t)id, (uint32_t)above_id);
    OUTPUT:
        RETVAL

int
lower(self, id, below_id = 0)
        SV *self
        UV id
        UV below_id
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_lower(ps->scene, (uint32_t)id, (uint32_t)below_id);
    OUTPUT:
        RETVAL

int
add_tag(self, id, tag)
        SV *self
        UV id
        const char *tag
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_add_tag(ps->scene, (uint32_t)id, tag);
    OUTPUT:
        RETVAL

int
remove_tag(self, id, tag)
        SV *self
        UV id
        const char *tag
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_remove_tag(ps->scene, (uint32_t)id, tag);
    OUTPUT:
        RETVAL

int
has_tag(self, id, tag)
        SV *self
        UV id
        const char *tag
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_scene_has_tag(ps->scene, (uint32_t)id, tag);
    OUTPUT:
        RETVAL

SV *
get_tags(self, id)
        SV *self
        UV id
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        uint32_t n = tkmt_scene_get_tags(ps->scene, (uint32_t)id, NULL, 0);
        AV *av = newAV();
        if (n > 0) {
            const char **tags = (const char **)malloc((size_t)n * sizeof(const char *));
            if (tags) {
                tkmt_scene_get_tags(ps->scene, (uint32_t)id, tags, n);
                for (uint32_t i = 0; i < n; i++) {
                    av_push(av, newSVpv(tags[i], 0));
                }
                free(tags);
            }
        }
        RETVAL = newRV_noinc((SV *)av);
    OUTPUT:
        RETVAL

SV *
find_all(self)
        SV *self
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        uint32_t n = tkmt_scene_find_all(ps->scene, NULL, 0);
        uint32_t *ids = n ? (uint32_t *)malloc((size_t)n * sizeof(uint32_t)) : NULL;
        if (ids) tkmt_scene_find_all(ps->scene, ids, n);
        AV *av = ids_to_av(aTHX_ ids, ids ? n : 0);
        free(ids);
        RETVAL = newRV_noinc((SV *)av);
    OUTPUT:
        RETVAL

SV *
find_withtag(self, tag_or_id)
        SV *self
        const char *tag_or_id
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        uint32_t n = tkmt_scene_find_withtag(ps->scene, tag_or_id, NULL, 0);
        uint32_t *ids = n ? (uint32_t *)malloc((size_t)n * sizeof(uint32_t)) : NULL;
        if (ids) tkmt_scene_find_withtag(ps->scene, tag_or_id, ids, n);
        AV *av = ids_to_av(aTHX_ ids, ids ? n : 0);
        free(ids);
        RETVAL = newRV_noinc((SV *)av);
    OUTPUT:
        RETVAL

SV *
find_overlapping(self, x0, y0, x1, y1)
        SV *self
        double x0
        double y0
        double x1
        double y1
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        uint32_t n = tkmt_scene_find_overlapping(ps->scene,
                                                 (float)x0, (float)y0,
                                                 (float)x1, (float)y1, NULL, 0);
        uint32_t *ids = n ? (uint32_t *)malloc((size_t)n * sizeof(uint32_t)) : NULL;
        if (ids) {
            tkmt_scene_find_overlapping(ps->scene,
                                        (float)x0, (float)y0,
                                        (float)x1, (float)y1, ids, n);
        }
        AV *av = ids_to_av(aTHX_ ids, ids ? n : 0);
        free(ids);
        RETVAL = newRV_noinc((SV *)av);
    OUTPUT:
        RETVAL

SV *
find_enclosed(self, x0, y0, x1, y1)
        SV *self
        double x0
        double y0
        double x1
        double y1
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        uint32_t n = tkmt_scene_find_enclosed(ps->scene,
                                              (float)x0, (float)y0,
                                              (float)x1, (float)y1, NULL, 0);
        uint32_t *ids = n ? (uint32_t *)malloc((size_t)n * sizeof(uint32_t)) : NULL;
        if (ids) {
            tkmt_scene_find_enclosed(ps->scene,
                                     (float)x0, (float)y0,
                                     (float)x1, (float)y1, ids, n);
        }
        AV *av = ids_to_av(aTHX_ ids, ids ? n : 0);
        free(ids);
        RETVAL = newRV_noinc((SV *)av);
    OUTPUT:
        RETVAL

UV
find_closest(self, x, y, halo = 0.0)
        SV *self
        double x
        double y
        double halo
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = (UV)tkmt_scene_find_closest(ps->scene, (float)x, (float)y, (float)halo);
    OUTPUT:
        RETVAL

SV *
bbox(self, tag_sv = &PL_sv_undef)
        SV *self
        SV *tag_sv
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        const char *tag = (tag_sv && SvOK(tag_sv)) ? SvPV_nolen(tag_sv) : "all";
        float bb[4];
        if (!tkmt_scene_bbox(ps->scene, tag, bb)) {
            RETVAL = &PL_sv_undef;
        } else {
            AV *av = newAV();
            av_extend(av, 3);
            for (int i = 0; i < 4; i++) av_push(av, newSVnv((NV)bb[i]));
            RETVAL = newRV_noinc((SV *)av);
        }
    OUTPUT:
        RETVAL

SV *
tessellate(self, surf_sv = &PL_sv_undef)
        SV *self
        SV *surf_sv
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        const tkmt_gfx_backend_t *b = NULL;
        tkmt_gfx_surface_t *gs = NULL;
        if (surf_sv && SvROK(surf_sv)) {
            tkmt_perl_surface_t *surf = sv_to_surface(aTHX_ surf_sv);
            b  = surf->backend;
            gs = surf->surf;
        }
        const tkmt_draw_list_t *dl = tkmt_scene_tessellate(ps->scene, b, gs);
        HV *hv = newHV();
        (void)hv_stores(hv, "vertex_count",   newSVuv(dl ? (UV)dl->vertex_count : 0));
        (void)hv_stores(hv, "instance_count", newSVuv(dl ? (UV)dl->instance_count : 0));
        (void)hv_stores(hv, "cmd_count",      newSVuv(dl ? (UV)dl->cmd_count : 0));
        RETVAL = newRV_noinc((SV *)hv);
    OUTPUT:
        RETVAL

int
render(self, surf_sv)
        SV *self
        SV *surf_sv
    CODE:
        tkmt_perl_scene_t *ps    = sv_to_scene(aTHX_ self);
        tkmt_perl_surface_t *srf = sv_to_surface(aTHX_ surf_sv);
        RETVAL = tkmt_scene_render(ps->scene, srf->backend, srf->surf);
    OUTPUT:
        RETVAL

SV *
stats(self)
        SV *self
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        tkmt_scene_stats_t st;
        tkmt_scene_get_stats(ps->scene, &st);
        HV *hv = newHV();
        (void)hv_stores(hv, "item_count",        newSVuv((UV)st.item_count));
        (void)hv_stores(hv, "total_instances",   newSVuv((UV)st.total_instances));
        (void)hv_stores(hv, "tessellate_count",  newSVuv((UV)st.tessellate_count));
        (void)hv_stores(hv, "view_only_updates", newSVuv((UV)st.view_only_updates));
        (void)hv_stores(hv, "grid_rebuilds",     newSVuv((UV)st.grid_rebuilds));
        (void)hv_stores(hv, "cached_vertices",   newSVuv((UV)st.cached_vertices));
        (void)hv_stores(hv, "cached_instances",  newSVuv((UV)st.cached_instances));
        (void)hv_stores(hv, "cached_cmds",       newSVuv((UV)st.cached_cmds));
        RETVAL = newRV_noinc((SV *)hv);
    OUTPUT:
        RETVAL

int
atlas_using_freetype(self)
        SV *self
    CODE:
        tkmt_perl_scene_t *ps = sv_to_scene(aTHX_ self);
        RETVAL = tkmt_atlas_using_freetype(tkmt_scene_atlas(ps->scene));
    OUTPUT:
        RETVAL

# =========================================================================
# Native Tk host surface handle wrappers for external renderers
# =========================================================================

MODULE = Tcl::Tk::MT::Gfx   PACKAGE = Tcl::Tk::MT::Gfx

PROTOTYPES: DISABLE

UV
surface_create_raw(interp_ptr, widget_path, width = 320, height = 240)
        UV interp_ptr
        const char *widget_path
        int width
        int height
    CODE:
        if (!interp_ptr) {
            croak("Tcl::Tk::MT::Gfx::surface_create_raw: null interpreter pointer");
        }
        if (!widget_path || !widget_path[0]) {
            croak("Tcl::Tk::MT::Gfx::surface_create_raw: empty widget path");
        }
        tkmt_interp_t *bi = INT2PTR(tkmt_interp_t *, interp_ptr);
        char errbuf[512];
        errbuf[0] = '\0';
        tkmt_surface_t *surf = tkmt_surface_create(bi, widget_path, width, height,
                                                   errbuf, sizeof(errbuf));
        if (!surf) {
            croak("Tcl::Tk::MT::Gfx::surface_create_raw failed: %s",
                  errbuf[0] ? errbuf : "unknown error");
        }
        RETVAL = (UV)(uintptr_t)surf;
    OUTPUT:
        RETVAL

void
surface_destroy_raw(surface_ptr)
        UV surface_ptr
    CODE:
        if (surface_ptr) {
            tkmt_surface_t *surf = INT2PTR(tkmt_surface_t *, surface_ptr);
            tkmt_surface_destroy(surf);
        }

SV *
surface_native_info(surface_ptr)
        UV surface_ptr
    CODE:
        tkmt_native_surface_t ns;
        memset(&ns, 0, sizeof(ns));
        ns.platform = TKMT_SURFACE_NONE;
        ns.scale    = 1.0f;
        int realized = 0;
        if (surface_ptr) {
            tkmt_surface_t *surf = INT2PTR(tkmt_surface_t *, surface_ptr);
            realized = tkmt_surface_get_native(surf, &ns);
        }
        double scale = (ns.scale > 0.0f) ? (double)ns.scale : 1.0;
#if defined(__APPLE__) && defined(__LP64__)
        if (ns.platform == TKMT_SURFACE_COCOA && ns.view != NULL && scale <= 1.0) {
            scale = tkmt_cocoa_view_scale(ns.view);
        }
#endif
        HV *hv = newHV();
        (void)hv_stores(hv, "platform",    newSVpv(tkmt_surface_platform_name(ns.platform), 0));
        (void)hv_stores(hv, "view_ptr",    newSVuv((UV)(uintptr_t)ns.view));
        (void)hv_stores(hv, "display_ptr", newSVuv((UV)(uintptr_t)ns.display));
        (void)hv_stores(hv, "window_id",   newSVuv((UV)ns.window));
        (void)hv_stores(hv, "x",           newSViv((IV)ns.x));
        (void)hv_stores(hv, "y",           newSViv((IV)ns.y));
        (void)hv_stores(hv, "width",       newSViv((IV)ns.width));
        (void)hv_stores(hv, "height",      newSViv((IV)ns.height));
        (void)hv_stores(hv, "scale",       newSVnv(scale));
        (void)hv_stores(hv, "visible",     newSViv((IV)(ns.visible ? 1 : 0)));
        (void)hv_stores(hv, "surface_ptr", newSVuv(surface_ptr));
        (void)hv_stores(hv, "realized",    newSViv((IV)(realized ? 1 : 0)));
        RETVAL = newRV_noinc((SV *)hv);
    OUTPUT:
        RETVAL

int
surface_set_ext_geometry_cb(surface_ptr, ud_ptr = 0, on_geom_fn_ptr = 0, on_detach_fn_ptr = 0)
        UV surface_ptr
        UV ud_ptr
        UV on_geom_fn_ptr
        UV on_detach_fn_ptr
    CODE:
        if (!surface_ptr) {
            RETVAL = 0;
        } else {
            tkmt_surface_t *surf = INT2PTR(tkmt_surface_t *, surface_ptr);
            void *ud = (ud_ptr != 0) ? INT2PTR(void *, ud_ptr) : NULL;
            tkmt_surface_geometry_fn on_geom   = tkmt_uv_to_geometry_fn(on_geom_fn_ptr);
            tkmt_surface_detach_fn   on_detach = tkmt_uv_to_detach_fn(on_detach_fn_ptr);
            tkmt_surface_set_geometry_cb(surf, ud, on_geom, on_detach);
            RETVAL = 1;
        }
    OUTPUT:
        RETVAL

void
surface_request_redraw(surface_ptr)
        UV surface_ptr
    CODE:
        if (surface_ptr) {
            tkmt_surface_t *surf = INT2PTR(tkmt_surface_t *, surface_ptr);
            tkmt_surface_request_redraw(surf);
        }
