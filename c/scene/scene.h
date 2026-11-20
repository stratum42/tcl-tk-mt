/*
 * Tcl::Tk::MT - Retained 2D Scene Graph, Spatial Index, Tessellator & Atlas (C11)
 *
 * Pure C11 retained 2D scene graph targeting tkmt_draw_list_t (c/gfx/tkmt_gfx.h).
 * Features:
 *   - Contiguous item slab with O(1) ID lookup and O(1) z-order linked list
 *   - Interned tag bitsets (256 inline fast-path tags + overflow)
 *   - Uniform hash-grid spatial index for overlapping/enclosed/closest/frustum queries
 *   - Dirty tracking & batch_depth coalescing; pan/zoom updates only a 3x3 matrix
 *     with zero re-tessellation
 *   - Polyline (joins/caps/dashes), ear-clipping polygon, SDF instance, text, and
 *     image tessellator producing tkmt_draw_list_t
 *   - FreeType + HarfBuzz glyph atlas (when TKMT_HAVE_FREETYPE_HARFBUZZ=1) with
 *     built-in zero-dependency 8x8 bitmap fallback font
 */

#ifndef TKMT_SCENE_H
#define TKMT_SCENE_H

#include <stddef.h>
#include <stdint.h>
#include "../gfx/tkmt_gfx.h"

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
 * Item types, style enums, and flags
 * ------------------------------------------------------------------------- */

typedef enum tkmt_item_type {
    TKMT_ITEM_NONE           = 0,
    TKMT_ITEM_LINE           = 1,
    TKMT_ITEM_RECTANGLE      = 2,
    TKMT_ITEM_OVAL           = 3,
    TKMT_ITEM_ARC            = 4,
    TKMT_ITEM_POLYGON        = 5,
    TKMT_ITEM_TEXT           = 6,
    TKMT_ITEM_IMAGE          = 7,
    TKMT_ITEM_WINDOW         = 8,
    TKMT_ITEM_INSTANCE_BATCH = 9
} tkmt_item_type_t;

typedef enum tkmt_cap_style {
    TKMT_CAP_BUTT       = 0,
    TKMT_CAP_ROUND      = 1,
    TKMT_CAP_PROJECTING = 2
} tkmt_cap_style_t;

typedef enum tkmt_join_style {
    TKMT_JOIN_MITER = 0,
    TKMT_JOIN_ROUND = 1,
    TKMT_JOIN_BEVEL = 2
} tkmt_join_style_t;

typedef enum tkmt_arc_style {
    TKMT_ARC_PIESLICE = 0,
    TKMT_ARC_CHORD    = 1,
    TKMT_ARC_ARC      = 2
} tkmt_arc_style_t;

typedef enum tkmt_anchor {
    TKMT_ANCHOR_CENTER = 0,
    TKMT_ANCHOR_NW     = 1,
    TKMT_ANCHOR_N      = 2,
    TKMT_ANCHOR_NE     = 3,
    TKMT_ANCHOR_W      = 4,
    TKMT_ANCHOR_E      = 5,
    TKMT_ANCHOR_SW     = 6,
    TKMT_ANCHOR_S      = 7,
    TKMT_ANCHOR_SE     = 8
} tkmt_anchor_t;

typedef enum tkmt_item_state {
    TKMT_STATE_NORMAL   = 0,
    TKMT_STATE_DISABLED = 1,
    TKMT_STATE_HIDDEN   = 2
} tkmt_item_state_t;

#define TKMT_ITEM_FLAG_AA     (1u << 0)
#define TKMT_ITEM_FLAG_SMOOTH (1u << 1)
#define TKMT_ITEM_FLAG_CLOSED (1u << 2)

#define TKMT_DIRTY_NONE     0u
#define TKMT_DIRTY_GEOMETRY (1u << 0)
#define TKMT_DIRTY_VIEW     (1u << 1)
#define TKMT_DIRTY_GRID     (1u << 2)

#define TKMT_TAG_INLINE_WORDS 4
#define TKMT_TAG_INLINE_MAX   (TKMT_TAG_INLINE_WORDS * 64) /* 256 fast bitset tags */
#define TKMT_MAX_DASH         8

/* -------------------------------------------------------------------------
 * Glyph & Image Atlas (c/scene/atlas.c)
 * ------------------------------------------------------------------------- */

typedef struct tkmt_glyph_quad {
    float x0, y0, x1, y1; /* local position relative to text origin */
    float u0, v0, u1, v1; /* normalized UV in atlas texture */
} tkmt_glyph_quad_t;

typedef struct tkmt_atlas tkmt_atlas_t;

tkmt_atlas_t *tkmt_atlas_create(uint32_t width, uint32_t height);
void          tkmt_atlas_destroy(tkmt_atlas_t *atlas);

/* Ensure atlas R8 texture is uploaded/synced to the given gfx backend & surface.
 * Returns the backend texture ID (or 0 if backend/surface is NULL). */
tkmt_tex_id_t tkmt_atlas_sync_texture(tkmt_atlas_t *atlas,
                                      const tkmt_gfx_backend_t *backend,
                                      tkmt_gfx_surface_t *surf);

/* Reset bound texture ID when surface changes/destroys */
void tkmt_atlas_detach_texture(tkmt_atlas_t *atlas);

/* Shape/layout UTF-8 text into glyph quads.
 * Returns total glyph quad count written (up to max_quads; if out_quads==NULL,
 * returns required count). Writes total bounding width/height if non-NULL. */
uint32_t tkmt_atlas_layout_text(tkmt_atlas_t *atlas,
                                const char *text,
                                const char *font_family,
                                float font_size,
                                tkmt_glyph_quad_t *out_quads,
                                uint32_t max_quads,
                                float *out_width,
                                float *out_height);

/* Measure text dimensions without emitting quads */
void tkmt_atlas_measure_text(tkmt_atlas_t *atlas,
                             const char *text,
                             const char *font_family,
                             float font_size,
                             float *out_width,
                             float *out_height);

/* Returns 1 if FreeType+HarfBuzz is active with a loaded font, 0 if fallback bitmap */
int tkmt_atlas_using_freetype(const tkmt_atlas_t *atlas);

/* Access raw R8 atlas buffer (for tests/inspection) */
const uint8_t *tkmt_atlas_pixels(const tkmt_atlas_t *atlas,
                                 uint32_t *out_w, uint32_t *out_h);

/* -------------------------------------------------------------------------
 * Scene Item & Scene Structs
 * ------------------------------------------------------------------------- */

typedef struct tkmt_scene_item {
    uint32_t          id;       /* 1-based Tk item ID; 0 = free slot */
    tkmt_item_type_t  type;
    tkmt_item_state_t state;
    uint32_t          flags;    /* TKMT_ITEM_FLAG_* */

    /* Z-order doubly linked list (slot indices, -1 = none) */
    int32_t           z_prev;
    int32_t           z_next;

    /* World-space axis-aligned bounding box */
    float             bbox_x0, bbox_y0, bbox_x1, bbox_y1;

    /* Coordinates: [x0, y0, x1, y1, ...] */
    float            *coords;
    uint32_t          coord_count; /* number of floats (2 * num_points) */
    uint32_t          coord_cap;

    /* Visual styling */
    uint32_t          fill_color;    /* packed RGBA8888; alpha=0 => no fill */
    uint32_t          outline_color; /* packed RGBA8888; alpha=0 => no outline */
    float             width;         /* stroke width in world units */
    float             corner_radius; /* rounded rect corner radius */
    float             start_deg;     /* arc start angle in degrees */
    float             extent_deg;    /* arc extent angle in degrees */
    tkmt_cap_style_t  cap_style;
    tkmt_join_style_t join_style;
    tkmt_arc_style_t  arc_style;
    tkmt_anchor_t     anchor;

    /* Dash pattern */
    float             dash[TKMT_MAX_DASH];
    uint8_t           dash_count;
    float             dash_offset;

    /* Text payload */
    char             *text;
    char             *font_family;
    float             font_size;

    /* Image payload */
    tkmt_tex_id_t     tex_id;
    uint32_t          img_w;
    uint32_t          img_h;

    /* Embedded Tk window payload */
    char             *window_path;
    float             win_w;
    float             win_h;

    /* High-volume instanced shape batch (100k+ shapes) */
    tkmt_instance_t  *instances;
    uint32_t          inst_count;
    uint32_t          inst_cap;

    /* Tag membership */
    uint64_t          tag_bits[TKMT_TAG_INLINE_WORDS];
    uint32_t         *extra_tags;
    uint32_t          extra_tag_count;
    uint32_t          extra_tag_cap;

    /* Spatial grid dedup visit stamp */
    uint32_t          visit_gen;
} tkmt_scene_item_t;

typedef struct tkmt_scene_stats {
    uint32_t item_count;
    uint32_t total_instances;
    uint64_t tessellate_count;
    uint64_t view_only_updates;
    uint64_t grid_rebuilds;
    uint32_t cached_vertices;
    uint32_t cached_instances;
    uint32_t cached_cmds;
} tkmt_scene_stats_t;

typedef struct tkmt_grid_node {
    int32_t slot;
    int32_t cx;
    int32_t cy;
    int32_t next;
} tkmt_grid_node_t;

#define TKMT_GRID_BUCKETS 4096u

typedef struct tkmt_scene {
    uint32_t           viewport_w;
    uint32_t           viewport_h;
    uint32_t           clear_color;
    int                do_clear;
    float              view_matrix[9];
    int                batch_depth;
    uint32_t           dirty_flags;

    /* Contiguous item slab */
    tkmt_scene_item_t *items;
    uint32_t           item_cap;
    uint32_t           item_count;
    int32_t           *free_slots;
    uint32_t           free_count;
    uint32_t           free_cap;
    int32_t           *id_to_slot;
    uint32_t           id_table_cap;
    uint32_t           next_id;
    int32_t            z_head;
    int32_t            z_tail;

    /* Interned tag table */
    char             **tag_names;
    uint32_t           tag_count;
    uint32_t           tag_cap;

    /* Uniform hash-grid spatial index */
    float              grid_cell_size;
    int32_t           *grid_heads;
    tkmt_grid_node_t  *grid_nodes;
    uint32_t           grid_node_count;
    uint32_t           grid_node_cap;
    uint32_t           visit_gen;

    /* Retained draw list cache */
    tkmt_vertex_t     *dl_verts;
    uint32_t           dl_vert_count;
    uint32_t           dl_vert_cap;
    tkmt_instance_t   *dl_insts;
    uint32_t           dl_inst_count;
    uint32_t           dl_inst_cap;
    tkmt_draw_cmd_t   *dl_cmds;
    uint32_t           dl_cmd_count;
    uint32_t           dl_cmd_cap;
    tkmt_draw_list_t   draw_list;
    int                draw_list_valid;

    /* Glyph atlas */
    tkmt_atlas_t      *atlas;

    /* Telemetry */
    uint64_t           tessellate_count;
    uint64_t           view_only_updates;
    uint64_t           grid_rebuilds;
} tkmt_scene_t;

/* -------------------------------------------------------------------------
 * Scene Lifecycle & Batching
 * ------------------------------------------------------------------------- */

tkmt_scene_t *tkmt_scene_create(uint32_t viewport_w, uint32_t viewport_h);
void          tkmt_scene_destroy(tkmt_scene_t *scene);

void tkmt_scene_set_viewport(tkmt_scene_t *scene, uint32_t w, uint32_t h);
void tkmt_scene_get_viewport(const tkmt_scene_t *scene, uint32_t *out_w, uint32_t *out_h);
void tkmt_scene_set_clear_color(tkmt_scene_t *scene, uint32_t rgba, int do_clear);

/* Batching: defers dirty notifications while batch_depth > 0 */
void tkmt_scene_batch_begin(tkmt_scene_t *scene);
void tkmt_scene_batch_end(tkmt_scene_t *scene);
int  tkmt_scene_batch_depth(const tkmt_scene_t *scene);

/* View transform (3x3 row-major affine matrix).
 * Modifies ONLY TKMT_DIRTY_VIEW; triggers zero re-tessellation. */
void tkmt_scene_set_view_matrix(tkmt_scene_t *scene, const float m[9]);
void tkmt_scene_get_view_matrix(const tkmt_scene_t *scene, float out_m[9]);
void tkmt_scene_set_pan_zoom(tkmt_scene_t *scene, float tx, float ty, float sx, float sy);
void tkmt_scene_pan(tkmt_scene_t *scene, float dx, float dy);
void tkmt_scene_zoom(tkmt_scene_t *scene, float factor, float cx, float cy);

/* -------------------------------------------------------------------------
 * Item Creation & Deletion
 * ------------------------------------------------------------------------- */

uint32_t tkmt_scene_create_item(tkmt_scene_t *scene,
                                tkmt_item_type_t type,
                                const float *coords,
                                uint32_t coord_count);

/* Bulk create multiple 2-point line segments from packed [x0,y0,x1,y1, ...] */
uint32_t tkmt_scene_create_lines_batch(tkmt_scene_t *scene,
                                       const float *xy_pairs,
                                       uint32_t segment_count,
                                       uint32_t color,
                                       float width,
                                       uint32_t *out_ids);

/* Create an instanced batch item from packed [x, y, w, h, rgba_f32_or_u32] or
 * directly from tkmt_instance_t array. */
uint32_t tkmt_scene_create_instances(tkmt_scene_t *scene,
                                     const tkmt_instance_t *instances,
                                     uint32_t count);

int  tkmt_scene_delete_item(tkmt_scene_t *scene, uint32_t id);
uint32_t tkmt_scene_delete_by_tag(tkmt_scene_t *scene, const char *tag_or_id);
void tkmt_scene_clear(tkmt_scene_t *scene);

/* Lookup item (mutable/const pointer valid until next structural mutation) */
tkmt_scene_item_t       *tkmt_scene_get_item(tkmt_scene_t *scene, uint32_t id);
const tkmt_scene_item_t *tkmt_scene_get_item_const(const tkmt_scene_t *scene, uint32_t id);

/* -------------------------------------------------------------------------
 * Item Mutation (coords, style, text, image, window, z-order, transforms)
 * ------------------------------------------------------------------------- */

int tkmt_scene_set_coords(tkmt_scene_t *scene, uint32_t id,
                          const float *coords, uint32_t coord_count);
int tkmt_scene_set_coords_double(tkmt_scene_t *scene, uint32_t id,
                                 const double *coords, uint32_t coord_count);

int tkmt_scene_set_fill(tkmt_scene_t *scene, uint32_t id, uint32_t rgba);
int tkmt_scene_set_outline(tkmt_scene_t *scene, uint32_t id, uint32_t rgba);
int tkmt_scene_set_width(tkmt_scene_t *scene, uint32_t id, float width);
int tkmt_scene_set_corner_radius(tkmt_scene_t *scene, uint32_t id, float radius);
int tkmt_scene_set_arc_angles(tkmt_scene_t *scene, uint32_t id,
                              float start_deg, float extent_deg,
                              tkmt_arc_style_t style);
int tkmt_scene_set_line_style(tkmt_scene_t *scene, uint32_t id,
                              tkmt_cap_style_t cap, tkmt_join_style_t join,
                              const float *dash, uint8_t dash_count, float dash_offset);
int tkmt_scene_set_state(tkmt_scene_t *scene, uint32_t id, tkmt_item_state_t state);
int tkmt_scene_set_flags(tkmt_scene_t *scene, uint32_t id, uint32_t flags);
int tkmt_scene_set_anchor(tkmt_scene_t *scene, uint32_t id, tkmt_anchor_t anchor);
int tkmt_scene_set_text(tkmt_scene_t *scene, uint32_t id,
                        const char *text, const char *font_family, float font_size);
int tkmt_scene_set_image(tkmt_scene_t *scene, uint32_t id,
                         tkmt_tex_id_t tex_id, uint32_t img_w, uint32_t img_h);
int tkmt_scene_set_window(tkmt_scene_t *scene, uint32_t id,
                          const char *window_path, float w, float h);
int tkmt_scene_update_instances(tkmt_scene_t *scene, uint32_t id,
                                const tkmt_instance_t *instances, uint32_t count);

int tkmt_scene_move(tkmt_scene_t *scene, const char *tag_or_id, float dx, float dy);
int tkmt_scene_scale(tkmt_scene_t *scene, const char *tag_or_id,
                     float ox, float oy, float sx, float sy);
int tkmt_scene_raise(tkmt_scene_t *scene, uint32_t id, uint32_t above_id);
int tkmt_scene_lower(tkmt_scene_t *scene, uint32_t id, uint32_t below_id);

/* -------------------------------------------------------------------------
 * Tags (interned bitsets)
 * ------------------------------------------------------------------------- */

uint32_t tkmt_scene_intern_tag(tkmt_scene_t *scene, const char *tag);
int      tkmt_scene_add_tag(tkmt_scene_t *scene, uint32_t id, const char *tag);
int      tkmt_scene_remove_tag(tkmt_scene_t *scene, uint32_t id, const char *tag);
int      tkmt_scene_has_tag(const tkmt_scene_t *scene, uint32_t id, const char *tag);
/* Writes up to max_tags tag name pointers into out_tags; returns total tag count */
uint32_t tkmt_scene_get_tags(const tkmt_scene_t *scene, uint32_t id,
                             const char **out_tags, uint32_t max_tags);

/* -------------------------------------------------------------------------
 * Hit-Testing, Spatial Queries & Bounding Box
 * ------------------------------------------------------------------------- */

uint32_t tkmt_scene_find_all(const tkmt_scene_t *scene,
                             uint32_t *out_ids, uint32_t max_ids);
uint32_t tkmt_scene_find_withtag(const tkmt_scene_t *scene, const char *tag_or_id,
                                 uint32_t *out_ids, uint32_t max_ids);
uint32_t tkmt_scene_find_overlapping(tkmt_scene_t *scene,
                                     float x0, float y0, float x1, float y1,
                                     uint32_t *out_ids, uint32_t max_ids);
uint32_t tkmt_scene_find_enclosed(tkmt_scene_t *scene,
                                  float x0, float y0, float x1, float y1,
                                  uint32_t *out_ids, uint32_t max_ids);
uint32_t tkmt_scene_find_closest(tkmt_scene_t *scene,
                                 float x, float y, float halo);

/* Returns 1 if non-empty bbox found, 0 if no matching items */
int tkmt_scene_bbox(const tkmt_scene_t *scene, const char *tag_or_id,
                    float out_bbox[4]);

/* -------------------------------------------------------------------------
 * Tessellation & Rendering (c/scene/tessellate.c)
 * ------------------------------------------------------------------------- */

/* Access scene's internal glyph atlas */
tkmt_atlas_t *tkmt_scene_atlas(tkmt_scene_t *scene);

/* Build/update cached tkmt_draw_list_t.
 * If only view_matrix changed (TKMT_DIRTY_VIEW without TKMT_DIRTY_GEOMETRY),
 * updates view_matrix in O(1) with ZERO re-tessellation. */
const tkmt_draw_list_t *tkmt_scene_tessellate(tkmt_scene_t *scene,
                                              const tkmt_gfx_backend_t *backend,
                                              tkmt_gfx_surface_t *surf);

/* Convenience: tessellate + sync atlas + submit to backend->render(surf, dl) */
int tkmt_scene_render(tkmt_scene_t *scene,
                      const tkmt_gfx_backend_t *backend,
                      tkmt_gfx_surface_t *surf);

/* Scene telemetry */
void tkmt_scene_get_stats(const tkmt_scene_t *scene, tkmt_scene_stats_t *out);

/* -------------------------------------------------------------------------
 * Internal helpers shared between scene.c and tessellate.c
 * ------------------------------------------------------------------------- */

void tkmt_scene_recompute_item_bbox(tkmt_scene_t *scene, tkmt_scene_item_t *it);

#ifdef __cplusplus
}
#endif

#endif /* TKMT_SCENE_H */
