/*
 * c/tcl_bridge/tk_surface.h - Tk host frame & native GPU surface handle manager
 *
 * Pure C11. Creates a Tk host frame, hooks Tk_CreateEventHandler for
 * StructureNotifyMask | ExposureMask | VisibilityChangeMask, extracts the
 * platform native handle (macOS NSView*, X11 Window + Display*, Win32 HWND),
 * manages createWindow embedded Tk subwindows, and coalesces redraws via
 * Tcl_DoWhenIdle.
 */
#ifndef TKMT_TK_SURFACE_H
#define TKMT_TK_SURFACE_H

#include "tcl_bridge.h"
#include <stdint.h>

typedef struct tkmt_surface tkmt_surface_t;

typedef enum tkmt_surface_platform {
    TKMT_SURFACE_NONE  = 0,
    TKMT_SURFACE_COCOA = 1, /* macOS NSView* in .view */
    TKMT_SURFACE_X11   = 2, /* X11 Display* in .display, Window XID in .window */
    TKMT_SURFACE_WIN32 = 3  /* Win32 HWND in .view and .window */
} tkmt_surface_platform_t;

typedef struct tkmt_native_surface {
    tkmt_surface_platform_t platform;
    void     *view;     /* macOS NSView*, Win32 HWND, or NULL */
    void     *display;  /* X11 Display*, else NULL */
    uintptr_t window;   /* X11 Window XID, Win32 HWND cast, or 0 */
    int       x;        /* logical x relative to toplevel content area */
    int       y;        /* logical y relative to toplevel content area */
    int       width;    /* logical width in px */
    int       height;   /* logical height in px */
    float     scale;    /* HiDPI backing scale factor */
    int       visible;  /* 1 if mapped (including all ancestors) and visible */
} tkmt_native_surface_t;

typedef void (*tkmt_surface_render_fn)(void *userdata, const tkmt_native_surface_t *surf);
typedef void (*tkmt_surface_resize_fn)(void *userdata, int width, int height, float scale);
typedef void (*tkmt_surface_destroy_fn)(void *userdata);
typedef void (*tkmt_surface_geometry_fn)(void *userdata,
                                         int x, int y, int width, int height,
                                         int visible);
typedef void (*tkmt_surface_detach_fn)(void *userdata);

/* Create a Tk frame at widget_path and attach event/surface tracking */
tkmt_surface_t *tkmt_surface_create(tkmt_interp_t *bi, const char *widget_path,
                                    int width, int height,
                                    char *errbuf, size_t errbuf_len);

/* Destroy surface tracking (does not destroy Tk widget if already destroyed) */
void            tkmt_surface_destroy(tkmt_surface_t *surf);

/* Register render/resize/destroy callbacks (e.g. from scene/gfx layer) */
void            tkmt_surface_set_callbacks(tkmt_surface_t *surf, void *userdata,
                                           tkmt_surface_render_fn on_render,
                                           tkmt_surface_resize_fn on_resize,
                                           tkmt_surface_destroy_fn on_destroy);

/* Register geometry/visibility callback (e.g. to sync macOS Metal child NSView).
 * Fires immediately with current geometry if non-NULL; on_detach fires if
 * tkmt_surface_destroy runs while the callback is still attached. */
void            tkmt_surface_set_geometry_cb(tkmt_surface_t *surf, void *userdata,
                                             tkmt_surface_geometry_fn on_geometry,
                                             tkmt_surface_detach_fn on_detach);

/* Query current native surface handle & geometry (returns 1 if realized) */
int             tkmt_surface_get_native(tkmt_surface_t *surf, tkmt_native_surface_t *out);

/* Coalesce a redraw via Tcl_DoWhenIdle */
void            tkmt_surface_request_redraw(tkmt_surface_t *surf);

/* Query Tk widget path */
const char     *tkmt_surface_path(const tkmt_surface_t *surf);

/* Manage embedded Tk child widgets (Canvas createWindow items) */
int             tkmt_surface_place_child(tkmt_surface_t *surf, const char *child_path,
                                         int x, int y, int width, int height, int visible);
int             tkmt_surface_remove_child(tkmt_surface_t *surf, const char *child_path);

/* Fast helper to blit an RGBA8888 buffer into a Tk Photo image */
int             tkmt_surface_blit_rgba_photo(tkmt_interp_t *bi, const char *photo_name,
                                             const uint8_t *rgba, int width, int height);

#endif /* TKMT_TK_SURFACE_H */
