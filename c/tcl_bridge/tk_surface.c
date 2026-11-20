/*
 * c/tcl_bridge/tk_surface.c - Tk host frame & native GPU surface handle manager
 *
 * Pure C11 implementation.
 */
#include "tk_surface.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>

typedef UINT (WINAPI *tkmt_get_dpi_for_window_fn)(HWND);

static float
tkmt_win32_query_scale(HWND hwnd)
{
    HMODULE u32 = GetModuleHandleA("user32.dll");
    if (u32 && hwnd) {
        FARPROC raw = GetProcAddress(u32, "GetDpiForWindow");
        if (raw) {
            tkmt_get_dpi_for_window_fn fn = NULL;
            memcpy(&fn, &raw, sizeof(fn));
            UINT dpi = fn(hwnd);
            if (dpi >= 48u && dpi <= 960u) {
                return (float)dpi / 96.0f;
            }
        }
    }
    if (hwnd) {
        HDC hdc = GetDC(hwnd);
        if (hdc) {
            int dpi = GetDeviceCaps(hdc, LOGPIXELSX);
            ReleaseDC(hwnd, hdc);
            if (dpi >= 48 && dpi <= 960) {
                return (float)dpi / 96.0f;
            }
        }
    }
    return 1.0f;
}
#endif

static char *
tkmt_strdup(const char *s)
{
    if (!s) return NULL;
    size_t n = strlen(s) + 1u;
    char *copy = (char *)malloc(n);
    if (copy) memcpy(copy, s, n);
    return copy;
}

#define TKMT_MAX_ANCESTORS 32

struct tkmt_surface {
    tkmt_interp_t           *bi;
    Tk_Window                tkwin;
    char                    *path;
    int                      x;
    int                      y;
    int                      width;
    int                      height;
    float                    scale;
    int                      visible;
    int                      redraw_pending;
    int                      destroyed;
    void                    *userdata;
    tkmt_surface_render_fn   on_render;
    tkmt_surface_resize_fn   on_resize;
    tkmt_surface_destroy_fn  on_destroy;
    void                    *geom_userdata;
    tkmt_surface_geometry_fn on_geometry;
    tkmt_surface_detach_fn   on_detach;
    Tk_Window                ancestors[TKMT_MAX_ANCESTORS];
    int                      ancestor_count;
};

static void tkmt_surface_idle_render(void *client_data);
static void tkmt_surface_event_proc(void *client_data, XEvent *event_ptr);
static void tkmt_surface_ancestor_event_proc(void *client_data, XEvent *event_ptr);

static void
tkmt_surface_detach_ancestors(tkmt_surface_t *surf)
{
    if (!surf) return;
    for (int i = 0; i < surf->ancestor_count; i++) {
        if (surf->ancestors[i]) {
            Tk_DeleteEventHandler(
                surf->ancestors[i],
                StructureNotifyMask,
                tkmt_surface_ancestor_event_proc,
                surf
            );
            surf->ancestors[i] = NULL;
        }
    }
    surf->ancestor_count = 0;
}

static void
tkmt_surface_compute_geometry(tkmt_surface_t *surf,
                              int *out_x, int *out_y,
                              int *out_w, int *out_h,
                              int *out_vis)
{
    int x = 0, y = 0, w = 0, h = 0, vis = 0;
    if (surf && surf->tkwin && !surf->destroyed) {
        w = Tk_Width(surf->tkwin);
        h = Tk_Height(surf->tkwin);
        if (w <= 0) w = surf->width;
        if (h <= 0) h = surf->height;

        vis = 1;
        for (Tk_Window cur = surf->tkwin; cur != NULL; cur = Tk_Parent(cur)) {
            if (!Tk_IsMapped(cur)) {
                vis = 0;
            }
            if (Tk_IsTopLevel(cur)) {
                break;
            }
            x += Tk_X(cur) + Tk_Changes(cur)->border_width;
            y += Tk_Y(cur) + Tk_Changes(cur)->border_width;
        }
    }
    if (out_x)   *out_x   = x;
    if (out_y)   *out_y   = y;
    if (out_w)   *out_w   = w;
    if (out_h)   *out_h   = h;
    if (out_vis) *out_vis = vis;
}

static void
tkmt_surface_notify_geometry(tkmt_surface_t *surf, int force_hidden)
{
    if (!surf) return;
    int x = 0, y = 0, w = 0, h = 0, vis = 0;
    if (!surf->destroyed && surf->tkwin) {
        tkmt_surface_compute_geometry(surf, &x, &y, &w, &h, &vis);
        if (force_hidden) vis = 0;
        surf->x = x;
        surf->y = y;
        if (w > 0) surf->width = w;
        if (h > 0) surf->height = h;
        surf->visible = vis;
    } else {
        surf->visible = 0;
        vis = 0;
    }
    if (surf->on_geometry) {
        surf->on_geometry(surf->geom_userdata, surf->x, surf->y,
                          surf->width, surf->height, vis);
    }
}

static void
tkmt_surface_fill_native(tkmt_surface_t *surf, tkmt_native_surface_t *out)
{
    memset(out, 0, sizeof(*out));
    if (!surf || !surf->tkwin || surf->destroyed) {
        out->platform = TKMT_SURFACE_NONE;
        return;
    }

    int x = 0, y = 0, w = 0, h = 0, vis = 0;
    tkmt_surface_compute_geometry(surf, &x, &y, &w, &h, &vis);
    surf->x = x;
    surf->y = y;
    if (w > 0) surf->width = w;
    if (h > 0) surf->height = h;
    surf->visible = vis;

    out->x = surf->x;
    out->y = surf->y;
    out->width = surf->width > 0 ? surf->width : Tk_Width(surf->tkwin);
    out->height = surf->height > 0 ? surf->height : Tk_Height(surf->tkwin);
    out->scale = surf->scale > 0.0f ? surf->scale : 1.0f;
    out->visible = surf->visible;

    Window win = Tk_WindowId(surf->tkwin);
    if (win == None) {
        /* Force window creation if possible */
        Tk_MakeWindowExist(surf->tkwin);
        win = Tk_WindowId(surf->tkwin);
    }

#if defined(__APPLE__)
    out->platform = TKMT_SURFACE_COCOA;
    if (win != None) {
        out->view = TkMacOSXGetRootControl((Drawable)win);
        out->window = (uintptr_t)out->view;
    }
    out->display = NULL;
#elif defined(_WIN32)
    out->platform = TKMT_SURFACE_WIN32;
    if (win != None) {
        HWND hwnd = Tk_GetHWND(win);
        out->view = (void *)hwnd;
        out->window = (uintptr_t)hwnd;
        float dpi_scale = tkmt_win32_query_scale(hwnd);
        if (dpi_scale > 0.0f) {
            surf->scale = dpi_scale;
            out->scale = dpi_scale;
        }
    }
    out->display = NULL;
#else
    out->platform = TKMT_SURFACE_X11;
    out->display = (void *)Tk_Display(surf->tkwin);
    out->window = (uintptr_t)win;
    out->view = NULL;
#endif
}

static void
tkmt_surface_idle_render(void *client_data)
{
    tkmt_surface_t *surf = (tkmt_surface_t *)client_data;
    if (!surf) return;
    surf->redraw_pending = 0;
    if (surf->destroyed || !surf->on_render) return;

    tkmt_native_surface_t ns;
    tkmt_surface_fill_native(surf, &ns);
    surf->on_render(surf->userdata, &ns);
}

static void
tkmt_surface_ancestor_event_proc(void *client_data, XEvent *ev)
{
    tkmt_surface_t *surf = (tkmt_surface_t *)client_data;
    if (!surf || surf->destroyed) return;

    switch (ev->type) {
    case ConfigureNotify:
    case MapNotify:
        tkmt_surface_notify_geometry(surf, 0);
        break;
    case UnmapNotify:
        tkmt_surface_notify_geometry(surf, 1);
        break;
    case DestroyNotify:
        for (int i = 0; i < surf->ancestor_count; i++) {
            if (surf->ancestors[i] &&
                Tk_WindowId(surf->ancestors[i]) == ev->xdestroywindow.window)
            {
                surf->ancestors[i] = NULL;
            }
        }
        tkmt_surface_notify_geometry(surf, 1);
        break;
    default:
        break;
    }
}

static void
tkmt_surface_event_proc(void *client_data, XEvent *ev)
{
    tkmt_surface_t *surf = (tkmt_surface_t *)client_data;
    if (!surf || surf->destroyed) return;

    switch (ev->type) {
    case Expose:
        if (ev->xexpose.count == 0) {
            tkmt_surface_notify_geometry(surf, 0);
            tkmt_surface_request_redraw(surf);
        }
        break;
    case ConfigureNotify: {
        int nw = ev->xconfigure.width;
        int nh = ev->xconfigure.height;
        if (nw > 0 && nh > 0 && (nw != surf->width || nh != surf->height)) {
            surf->width = nw;
            surf->height = nh;
            if (surf->on_resize) {
                surf->on_resize(surf->userdata, nw, nh, surf->scale);
            }
        }
        tkmt_surface_notify_geometry(surf, 0);
        tkmt_surface_request_redraw(surf);
        break;
    }
    case MapNotify:
        tkmt_surface_notify_geometry(surf, 0);
        tkmt_surface_request_redraw(surf);
        break;
    case UnmapNotify:
        tkmt_surface_notify_geometry(surf, 1);
        break;
    case VisibilityNotify:
        surf->visible = (ev->xvisibility.state != VisibilityFullyObscured) ? 1 : 0;
        if (surf->visible) {
            tkmt_surface_notify_geometry(surf, 0);
            tkmt_surface_request_redraw(surf);
        }
        break;
    case DestroyNotify:
        tkmt_surface_detach_ancestors(surf);
        surf->destroyed = 1;
        surf->tkwin = NULL;
        tkmt_surface_notify_geometry(surf, 1);
        if (surf->redraw_pending) {
            Tcl_CancelIdleCall(tkmt_surface_idle_render, surf);
            surf->redraw_pending = 0;
        }
        if (surf->on_destroy) {
            surf->on_destroy(surf->userdata);
        }
        break;
    default:
        break;
    }
}

tkmt_surface_t *
tkmt_surface_create(tkmt_interp_t *bi, const char *widget_path,
                    int width, int height,
                    char *errbuf, size_t errbuf_len)
{
    if (!bi || !tkmt_interp_has_tk(bi) || !widget_path || !widget_path[0]) {
        if (errbuf && errbuf_len > 0) {
            snprintf(errbuf, errbuf_len, "tkmt_surface_create: invalid interpreter or widget path");
        }
        return NULL;
    }

    Tcl_Interp *interp = tkmt_interp_raw(bi);
    if (width <= 0) width = 320;
    if (height <= 0) height = 240;

    /* Create host Tk frame if it doesn't already exist */
    Tk_Window mainwin = Tk_MainWindow(interp);
    if (!mainwin) {
        if (errbuf && errbuf_len > 0) {
            snprintf(errbuf, errbuf_len, "tkmt_surface_create: no Tk main window");
        }
        return NULL;
    }

    Tk_Window tkwin = Tk_NameToWindow(interp, widget_path, mainwin);
    if (!tkwin) {
        char cmd[512];
        snprintf(cmd, sizeof(cmd),
                 "frame %s -width %d -height %d -container 0 -highlightthickness 0 -borderwidth 0",
                 widget_path, width, height);
        if (Tcl_EvalEx(interp, cmd, -1, 0) != TCL_OK) {
            if (errbuf && errbuf_len > 0) {
                snprintf(errbuf, errbuf_len, "%s", Tcl_GetStringResult(interp));
            }
            return NULL;
        }
        tkwin = Tk_NameToWindow(interp, widget_path, mainwin);
        if (!tkwin) {
            if (errbuf && errbuf_len > 0) {
                snprintf(errbuf, errbuf_len, "tkmt_surface_create: failed to resolve Tk_Window for %s", widget_path);
            }
            return NULL;
        }
    }

    tkmt_surface_t *surf = (tkmt_surface_t *)calloc(1, sizeof(tkmt_surface_t));
    if (!surf) {
        if (errbuf && errbuf_len > 0) {
            snprintf(errbuf, errbuf_len, "tkmt_surface_create: out of memory");
        }
        return NULL;
    }

    surf->bi = bi;
    surf->tkwin = tkwin;
    surf->path = tkmt_strdup(widget_path);
    surf->width = width;
    surf->height = height;
    surf->scale = 1.0f;
    tkmt_surface_compute_geometry(surf, &surf->x, &surf->y, NULL, NULL, &surf->visible);

    Tk_CreateEventHandler(
        tkwin,
        StructureNotifyMask | ExposureMask | VisibilityChangeMask,
        tkmt_surface_event_proc,
        surf
    );

    /* Track ancestor configure/map/unmap up to toplevel (handles ttk::notebook tabs & parent moves) */
    surf->ancestor_count = 0;
    for (Tk_Window anc = Tk_Parent(tkwin);
         anc != NULL && surf->ancestor_count < TKMT_MAX_ANCESTORS;
         anc = Tk_Parent(anc))
    {
        surf->ancestors[surf->ancestor_count++] = anc;
        Tk_CreateEventHandler(
            anc,
            StructureNotifyMask,
            tkmt_surface_ancestor_event_proc,
            surf
        );
        if (Tk_IsTopLevel(anc)) {
            break;
        }
    }

    return surf;
}

void
tkmt_surface_destroy(tkmt_surface_t *surf)
{
    if (!surf) return;
    if (surf->redraw_pending) {
        Tcl_CancelIdleCall(tkmt_surface_idle_render, surf);
        surf->redraw_pending = 0;
    }
    tkmt_surface_detach_ancestors(surf);
    if (surf->tkwin && !surf->destroyed) {
        Tk_DeleteEventHandler(
            surf->tkwin,
            StructureNotifyMask | ExposureMask | VisibilityChangeMask,
            tkmt_surface_event_proc,
            surf
        );
    }
    if (surf->on_detach) {
        tkmt_surface_detach_fn detach = surf->on_detach;
        void *ud = surf->geom_userdata;
        surf->on_detach = NULL;
        surf->on_geometry = NULL;
        surf->geom_userdata = NULL;
        detach(ud);
    }
    surf->destroyed = 1;
    surf->tkwin = NULL;
    free(surf->path);
    free(surf);
}

void
tkmt_surface_set_callbacks(tkmt_surface_t *surf, void *userdata,
                           tkmt_surface_render_fn on_render,
                           tkmt_surface_resize_fn on_resize,
                           tkmt_surface_destroy_fn on_destroy)
{
    if (!surf) return;
    surf->userdata = userdata;
    surf->on_render = on_render;
    surf->on_resize = on_resize;
    surf->on_destroy = on_destroy;
}

void
tkmt_surface_set_geometry_cb(tkmt_surface_t *surf, void *userdata,
                             tkmt_surface_geometry_fn on_geometry,
                             tkmt_surface_detach_fn on_detach)
{
    if (!surf) return;
    surf->geom_userdata = userdata;
    surf->on_geometry = on_geometry;
    surf->on_detach = on_detach;
    if (on_geometry) {
        tkmt_surface_notify_geometry(surf, 0);
    }
}

int
tkmt_surface_get_native(tkmt_surface_t *surf, tkmt_native_surface_t *out)
{
    if (!surf || !out) return 0;
    tkmt_surface_fill_native(surf, out);
    return (out->platform != TKMT_SURFACE_NONE && (out->view != NULL || out->window != 0)) ? 1 : 0;
}

void
tkmt_surface_request_redraw(tkmt_surface_t *surf)
{
    if (!surf || surf->destroyed || surf->redraw_pending) return;
    surf->redraw_pending = 1;
    Tcl_DoWhenIdle(tkmt_surface_idle_render, surf);
}

const char *
tkmt_surface_path(const tkmt_surface_t *surf)
{
    return surf ? surf->path : NULL;
}

int
tkmt_surface_place_child(tkmt_surface_t *surf, const char *child_path,
                         int x, int y, int width, int height, int visible)
{
    if (!surf || !surf->bi || surf->destroyed || !child_path || !child_path[0]) return 0;
    Tcl_Interp *interp = tkmt_interp_raw(surf->bi);
    if (!interp) return 0;

    char cmd[512];
    if (!visible) {
        snprintf(cmd, sizeof(cmd), "place forget %s", child_path);
    } else if (width > 0 && height > 0) {
        snprintf(cmd, sizeof(cmd),
                 "place %s -in %s -x %d -y %d -width %d -height %d -anchor nw",
                 child_path, surf->path, x, y, width, height);
    } else {
        snprintf(cmd, sizeof(cmd),
                 "place %s -in %s -x %d -y %d -anchor nw",
                 child_path, surf->path, x, y);
    }
    return Tcl_EvalEx(interp, cmd, -1, 0) == TCL_OK ? 1 : 0;
}

int
tkmt_surface_remove_child(tkmt_surface_t *surf, const char *child_path)
{
    if (!surf || !surf->bi || surf->destroyed || !child_path || !child_path[0]) return 0;
    Tcl_Interp *interp = tkmt_interp_raw(surf->bi);
    if (!interp) return 0;

    char cmd[512];
    snprintf(cmd, sizeof(cmd), "place forget %s", child_path);
    return Tcl_EvalEx(interp, cmd, -1, 0) == TCL_OK ? 1 : 0;
}

int
tkmt_surface_blit_rgba_photo(tkmt_interp_t *bi, const char *photo_name,
                             const uint8_t *rgba, int width, int height)
{
    if (!bi || !tkmt_interp_has_tk(bi) || !photo_name || !rgba || width <= 0 || height <= 0) {
        return 0;
    }
    Tcl_Interp *interp = tkmt_interp_raw(bi);
    Tk_PhotoHandle handle = Tk_FindPhoto(interp, photo_name);
    if (!handle) return 0;

    if (tkmt_tk_photo_set_size(interp, handle, width, height) != TCL_OK) {
        return 0;
    }

    Tk_PhotoImageBlock block;
    block.pixelPtr = (unsigned char *)rgba;
    block.width = width;
    block.height = height;
    block.pitch = width * 4;
    block.pixelSize = 4;
    block.offset[0] = 0; /* R */
    block.offset[1] = 1; /* G */
    block.offset[2] = 2; /* B */
    block.offset[3] = 3; /* A */

    return tkmt_tk_photo_put_block(
        interp, handle, &block, 0, 0, width, height, TK_PHOTO_COMPOSITE_SET
    ) == TCL_OK ? 1 : 0;
}
