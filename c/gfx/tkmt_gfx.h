/*
 * Tcl::Tk::MT - Hardware-Accelerated 2D Graphics Backend Interface (C11)
 *
 * Modeled on perl5-mt/accel/perl_accel.h:
 *   - Backend vtable & runtime registry (tkmt_gfx_backend_t)
 *   - Runtime probing with environment controls:
 *       TCL_TK_MT_ACCEL=auto|metal|vulkan|software|off
 *       PERL_FORCE_SCALAR=1 (forces deterministic software twin)
 *   - Telemetry counters (tkmt_gfx_stats_t)
 *   - Unified draw list (tkmt_draw_list_t) shared by scene tessellator
 *     and all rendering backends (Software CPU, macOS Metal, Linux/Win64 Vulkan).
 */

#ifndef TKMT_GFX_H
#define TKMT_GFX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * Backend identifiers, device classes, and capability bitmask
 * ------------------------------------------------------------------------- */

typedef enum tkmt_gfx_backend_id {
    TKMT_GFX_BACKEND_SOFTWARE = 0,
    TKMT_GFX_BACKEND_METAL    = 1,
    TKMT_GFX_BACKEND_VULKAN   = 2,
    TKMT_GFX_BACKEND_MAX
} tkmt_gfx_backend_id_t;

typedef enum tkmt_gfx_device_class {
    TKMT_GFX_DEV_CPU = 0,
    TKMT_GFX_DEV_GPU = 1
} tkmt_gfx_device_class_t;

#define TKMT_GFX_CAP_OFFSCREEN     (1u << 0)
#define TKMT_GFX_CAP_WINDOWED      (1u << 1)
#define TKMT_GFX_CAP_INSTANCING    (1u << 2)
#define TKMT_GFX_CAP_SDF           (1u << 3)
#define TKMT_GFX_CAP_GLYPH_ATLAS   (1u << 4)
#define TKMT_GFX_CAP_RGBA_TEXTURE  (1u << 5)
#define TKMT_GFX_CAP_HIDPI         (1u << 6)

/* -------------------------------------------------------------------------
 * Packed RGBA8888 color helpers (little-endian: R in bits 0..7, A in 24..31)
 * ------------------------------------------------------------------------- */

static inline uint32_t tkmt_rgba(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    return (uint32_t)r
         | ((uint32_t)g << 8)
         | ((uint32_t)b << 16)
         | ((uint32_t)a << 24);
}

static inline uint8_t tkmt_rgba_r(uint32_t c) { return (uint8_t)(c & 0xFFu); }
static inline uint8_t tkmt_rgba_g(uint32_t c) { return (uint8_t)((c >> 8) & 0xFFu); }
static inline uint8_t tkmt_rgba_b(uint32_t c) { return (uint8_t)((c >> 16) & 0xFFu); }
static inline uint8_t tkmt_rgba_a(uint32_t c) { return (uint8_t)((c >> 24) & 0xFFu); }

/* -------------------------------------------------------------------------
 * Native window surface descriptor
 * ------------------------------------------------------------------------- */

typedef enum tkmt_native_handle_type {
    TKMT_NATIVE_NONE    = 0, /* headless offscreen */
    TKMT_NATIVE_NSVIEW  = 1, /* macOS NSView* */
    TKMT_NATIVE_X11     = 2, /* X11 Display* + Window */
    TKMT_NATIVE_WAYLAND = 3, /* Wayland wl_display* + wl_surface* */
    TKMT_NATIVE_WIN32   = 4  /* Win32 HINSTANCE + HWND */
} tkmt_native_handle_type_t;

typedef struct tkmt_surface_desc {
    uint32_t                  width;          /* framebuffer pixel width */
    uint32_t                  height;         /* framebuffer pixel height */
    float                     scale;          /* HiDPI scale factor (default 1.0f) */
    tkmt_native_handle_type_t handle_type;    /* native window handle kind */
    void                     *native_display; /* Display*, wl_display*, HINSTANCE, or NULL */
    uintptr_t                 native_window;  /* NSView*, X11 Window, wl_surface*, HWND, or 0 */
    int                       headless;       /* 1 = offscreen only, 0 = windowed present */
} tkmt_surface_desc_t;

typedef struct tkmt_gfx_surface tkmt_gfx_surface_t;

/* -------------------------------------------------------------------------
 * Textures & Glyph Atlas
 * ------------------------------------------------------------------------- */

typedef enum tkmt_tex_format {
    TKMT_TEX_RGBA8 = 0, /* 4 bytes/pixel RGBA8888 (straight alpha) */
    TKMT_TEX_R8    = 1  /* 1 byte/pixel coverage mask (glyph atlas) */
} tkmt_tex_format_t;

typedef uint32_t tkmt_tex_id_t; /* 0 = invalid / no texture */

/* -------------------------------------------------------------------------
 * Draw primitives: vertices, SDF instances, commands, and draw list
 * ------------------------------------------------------------------------- */

/* Per-vertex layout (24 bytes) for triangles, textured quads, and glyphs */
typedef struct tkmt_vertex {
    float    x, y;  /* scene coordinates (transformed by view_matrix) */
    float    u, v;  /* normalized texture coordinates [0..1] */
    uint32_t color; /* packed RGBA8888 */
    uint32_t flags; /* reserved / per-vertex flags (0 for default) */
} tkmt_vertex_t;

/* Instanced 2D SDF shape kinds */
typedef enum tkmt_sdf_shape {
    TKMT_SDF_RECT         = 0, /* axis-aligned rectangle */
    TKMT_SDF_ROUNDED_RECT = 1, /* rounded rect: param0 = corner radius */
    TKMT_SDF_OVAL         = 2, /* ellipse / circle inscribed in [x, y, w, h] */
    TKMT_SDF_ARC          = 3, /* arc: param0 = start_rad, param1 = extent_rad */
    TKMT_SDF_QUAD_TEX     = 4  /* textured quad using cmd.tex_id */
} tkmt_sdf_shape_t;

#define TKMT_SDF_FLAG_AA          (1u << 0) /* smooth 1px AA; 0 = crisp integer non-AA */
#define TKMT_SDF_FLAG_ARC_PIE     (0u << 1)
#define TKMT_SDF_FLAG_ARC_CHORD   (1u << 1)
#define TKMT_SDF_FLAG_ARC_OUTLINE (2u << 1)
#define TKMT_SDF_FLAG_ARC_MASK    (3u << 1)

/* Per-instance layout (48 bytes, 16-byte aligned for Metal/Vulkan SSBOs) */
typedef struct tkmt_instance {
    float    x, y;         /* top-left in scene coordinates */
    float    w, h;         /* width and height in scene coordinates */
    uint32_t fill_color;   /* packed RGBA8888 fill (alpha=0 means no fill) */
    uint32_t stroke_color; /* packed RGBA8888 stroke (alpha=0 means no stroke) */
    float    stroke_width; /* stroke width in pixels (<=0 means no stroke) */
    float    param0;       /* rounded rect corner radius, or arc start angle (rad) */
    float    param1;       /* arc extent angle (rad) */
    uint32_t shape;        /* tkmt_sdf_shape_t */
    uint32_t flags;        /* TKMT_SDF_FLAG_* */
    uint32_t _pad;         /* explicit padding to 48 bytes */
} tkmt_instance_t;

typedef enum tkmt_draw_cmd_type {
    TKMT_CMD_TRIANGLES          = 0, /* solid/vertex-colored triangles */
    TKMT_CMD_TEXTURED_TRIANGLES = 1, /* RGBA8 textured triangles (Photo) */
    TKMT_CMD_GLYPHS             = 2, /* R8 glyph atlas textured triangles */
    TKMT_CMD_INSTANCES          = 3  /* instanced SDF 2D shapes */
} tkmt_draw_cmd_type_t;

#define TKMT_CMD_FLAG_AA (1u << 0)

typedef struct tkmt_clip_rect {
    int32_t x, y, w, h; /* framebuffer pixel scissor; w<=0 || h<=0 disables clip */
} tkmt_clip_rect_t;

typedef struct tkmt_draw_cmd {
    tkmt_draw_cmd_type_t type;
    uint32_t             first;  /* start index in vertices[] or instances[] */
    uint32_t             count;  /* vertex count (multiple of 3) or instance count */
    tkmt_tex_id_t        tex_id; /* texture handle for TEXTURED_TRIANGLES/GLYPHS/QUAD_TEX */
    tkmt_clip_rect_t     clip;   /* optional scissor rect */
    uint32_t             flags;  /* TKMT_CMD_FLAG_* */
} tkmt_draw_cmd_t;

typedef struct tkmt_draw_list {
    uint32_t               clear_color;    /* packed RGBA8888 clear color */
    int                    do_clear;       /* 1 = clear before drawing, 0 = preserve */
    float                  view_matrix[9]; /* row-major 3x3 affine scene->pixel transform */
    const tkmt_vertex_t   *vertices;
    uint32_t               vertex_count;
    const tkmt_instance_t *instances;
    uint32_t               instance_count;
    const tkmt_draw_cmd_t *cmds;
    uint32_t               cmd_count;
} tkmt_draw_list_t;

static inline void tkmt_mat3_identity(float m[9]) {
    m[0] = 1.0f; m[1] = 0.0f; m[2] = 0.0f;
    m[3] = 0.0f; m[4] = 1.0f; m[5] = 0.0f;
    m[6] = 0.0f; m[7] = 0.0f; m[8] = 1.0f;
}

static inline void tkmt_draw_list_init(tkmt_draw_list_t *dl) {
    dl->clear_color    = tkmt_rgba(255, 255, 255, 255);
    dl->do_clear       = 1;
    tkmt_mat3_identity(dl->view_matrix);
    dl->vertices       = NULL;
    dl->vertex_count   = 0;
    dl->instances      = NULL;
    dl->instance_count = 0;
    dl->cmds           = NULL;
    dl->cmd_count      = 0;
}

/* -------------------------------------------------------------------------
 * Backend vtable
 * ------------------------------------------------------------------------- */

typedef struct tkmt_gfx_backend {
    tkmt_gfx_backend_id_t   id;
    const char             *name;
    const char             *description;
    tkmt_gfx_device_class_t device_class;
    int                     priority; /* higher wins in TCL_TK_MT_ACCEL=auto */
    uint32_t                caps;     /* TKMT_GFX_CAP_* bitmask */

    /* Lifecycle & probing */
    int  (*probe)(void); /* returns 1 if usable on this host, 0 otherwise */
    int  (*init)(void);  /* returns 0 on success, <0 on failure */
    void (*shutdown)(void);

    /* Surface lifecycle */
    tkmt_gfx_surface_t *(*create_surface)(const tkmt_surface_desc_t *desc);
    void                (*destroy_surface)(tkmt_gfx_surface_t *surf);
    int                 (*resize_surface)(tkmt_gfx_surface_t *surf,
                                          uint32_t width, uint32_t height, float scale);

    /* Texture & glyph atlas management */
    tkmt_tex_id_t (*texture_create)(tkmt_gfx_surface_t *surf,
                                    uint32_t width, uint32_t height,
                                    tkmt_tex_format_t fmt, const uint8_t *pixels);
    int           (*texture_update)(tkmt_gfx_surface_t *surf, tkmt_tex_id_t tex,
                                    uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                                    const uint8_t *pixels);
    void          (*texture_destroy)(tkmt_gfx_surface_t *surf, tkmt_tex_id_t tex);

    /* Frame submission & RGBA8888 readback */
    int (*render)(tkmt_gfx_surface_t *surf, const tkmt_draw_list_t *list);
    int (*readback_rgba)(tkmt_gfx_surface_t *surf, uint8_t *out_rgba, size_t buf_bytes);
} tkmt_gfx_backend_t;

/* -------------------------------------------------------------------------
 * Stats telemetry & Registry API
 * ------------------------------------------------------------------------- */

typedef struct tkmt_gfx_stats {
    uint64_t    frames_rendered;
    uint64_t    draw_calls;
    uint64_t    vertices_submitted;
    uint64_t    instances_submitted;
    uint64_t    offload_calls;
    uint64_t    fallback_calls;
    uint64_t    readback_calls;
    const char *last_backend_name;
} tkmt_gfx_stats_t;

/* Registry lifecycle & discovery */
int                       tkmt_gfx_init(void);
void                      tkmt_gfx_shutdown(void);
int                       tkmt_gfx_register(const tkmt_gfx_backend_t *backend);
const tkmt_gfx_backend_t *tkmt_gfx_active(void);
const tkmt_gfx_backend_t *tkmt_gfx_find(const char *name);
size_t                    tkmt_gfx_list(const tkmt_gfx_backend_t **out, size_t max_out);
int                       tkmt_gfx_backend_available(const char *name);
int                       tkmt_gfx_is_enabled(void);

/* Telemetry & test helpers */
void tkmt_gfx_get_stats(tkmt_gfx_stats_t *out);
void tkmt_gfx_reset_stats(void);
void tkmt_gfx_reset_for_test(const char *mode_override);
void tkmt_gfx_record_frame(const char *backend_name, uint32_t draw_calls,
                           uint64_t vertices, uint64_t instances, int is_fallback);
void tkmt_gfx_record_readback(void);

/* Deterministic SHA-256 hex digest (64 hex chars + NUL) for readback parity */
void tkmt_gfx_sha256_hex(const uint8_t *data, size_t len, char out_hex[65]);

/* Built-in backend accessors (registered automatically by tkmt_gfx_init) */
const tkmt_gfx_backend_t *tkmt_gfx_get_software_backend(void);
const tkmt_gfx_backend_t *tkmt_gfx_get_metal_backend(void);
const tkmt_gfx_backend_t *tkmt_gfx_get_vulkan_backend(void);

#ifdef __cplusplus
}
#endif

#endif /* TKMT_GFX_H */
