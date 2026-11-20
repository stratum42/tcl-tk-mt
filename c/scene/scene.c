/*
 * Tcl::Tk::MT - Retained 2D Scene Graph & Uniform-Grid Spatial Index (C11)
 */

#include "scene.h"

#include <ctype.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static char *xstrdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p  = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static inline float minf(float a, float b) { return a < b ? a : b; }
static inline float maxf(float a, float b) { return a > b ? a : b; }

static inline void mark_dirty(tkmt_scene_t *s, uint32_t flags) {
    s->dirty_flags |= flags;
}

static uint32_t grid_hash(int32_t cx, int32_t cy) {
    uint32_t h = (uint32_t)cx * 73856093u ^ (uint32_t)cy * 19349663u;
    return h & (TKMT_GRID_BUCKETS - 1u);
}

static void grid_push_node(tkmt_scene_t *s, int32_t slot, int32_t cx, int32_t cy) {
    if (s->grid_node_count == s->grid_node_cap) {
        uint32_t ncap = s->grid_node_cap ? s->grid_node_cap * 2u : 256u;
        tkmt_grid_node_t *nn = (tkmt_grid_node_t *)realloc(
            s->grid_nodes, (size_t)ncap * sizeof(tkmt_grid_node_t));
        if (!nn) return;
        s->grid_nodes    = nn;
        s->grid_node_cap = ncap;
    }
    uint32_t b   = grid_hash(cx, cy);
    int32_t idx  = (int32_t)s->grid_node_count++;
    s->grid_nodes[idx].slot = slot;
    s->grid_nodes[idx].cx   = cx;
    s->grid_nodes[idx].cy   = cy;
    s->grid_nodes[idx].next = s->grid_heads[b];
    s->grid_heads[b]        = idx;
}

static void grid_insert_item(tkmt_scene_t *s, int32_t slot) {
    const tkmt_scene_item_t *it = &s->items[slot];
    if (it->id == 0 || it->state == TKMT_STATE_HIDDEN) return;

    float inv = 1.0f / s->grid_cell_size;
    int32_t cx0 = (int32_t)floorf(it->bbox_x0 * inv);
    int32_t cy0 = (int32_t)floorf(it->bbox_y0 * inv);
    int32_t cx1 = (int32_t)floorf(it->bbox_x1 * inv);
    int32_t cy1 = (int32_t)floorf(it->bbox_y1 * inv);

    int64_t span_x = (int64_t)cx1 - (int64_t)cx0 + 1;
    int64_t span_y = (int64_t)cy1 - (int64_t)cy0 + 1;
    if (span_x <= 0 || span_y <= 0 || span_x * span_y > 256) {
        /* Large/oversized item sentinel cell */
        grid_push_node(s, slot, INT32_MAX, INT32_MAX);
        return;
    }

    for (int32_t cy = cy0; cy <= cy1; cy++) {
        for (int32_t cx = cx0; cx <= cx1; cx++) {
            grid_push_node(s, slot, cx, cy);
        }
    }
}

static void grid_ensure_fresh(tkmt_scene_t *s) {
    if (!(s->dirty_flags & TKMT_DIRTY_GRID)) return;

    for (uint32_t i = 0; i < TKMT_GRID_BUCKETS; i++) {
        s->grid_heads[i] = -1;
    }
    s->grid_node_count = 0;

    for (int32_t slot = s->z_head; slot != -1; slot = s->items[slot].z_next) {
        grid_insert_item(s, slot);
    }

    s->dirty_flags &= ~TKMT_DIRTY_GRID;
    s->grid_rebuilds++;
}

static void anchor_offset(tkmt_anchor_t anchor, float w, float h,
                          float *ox, float *oy) {
    switch (anchor) {
        case TKMT_ANCHOR_NW:     *ox = 0.0f;      *oy = 0.0f;      break;
        case TKMT_ANCHOR_N:      *ox = -w * 0.5f; *oy = 0.0f;      break;
        case TKMT_ANCHOR_NE:     *ox = -w;        *oy = 0.0f;      break;
        case TKMT_ANCHOR_W:      *ox = 0.0f;      *oy = -h * 0.5f; break;
        case TKMT_ANCHOR_E:      *ox = -w;        *oy = -h * 0.5f; break;
        case TKMT_ANCHOR_SW:     *ox = 0.0f;      *oy = -h;        break;
        case TKMT_ANCHOR_S:      *ox = -w * 0.5f; *oy = -h;        break;
        case TKMT_ANCHOR_SE:     *ox = -w;        *oy = -h;        break;
        case TKMT_ANCHOR_CENTER:
        default:                 *ox = -w * 0.5f; *oy = -h * 0.5f; break;
    }
}

void tkmt_scene_recompute_item_bbox(tkmt_scene_t *scene, tkmt_scene_item_t *it) {
    if (!it) return;

    if (it->type == TKMT_ITEM_INSTANCE_BATCH) {
        if (it->inst_count == 0) {
            it->bbox_x0 = it->bbox_y0 = it->bbox_x1 = it->bbox_y1 = 0.0f;
            return;
        }
        float x0 = FLT_MAX, y0 = FLT_MAX, x1 = -FLT_MAX, y1 = -FLT_MAX;
        for (uint32_t i = 0; i < it->inst_count; i++) {
            const tkmt_instance_t *inst = &it->instances[i];
            float pad = inst->stroke_width > 0.0f ? inst->stroke_width * 0.5f : 0.0f;
            float ix0 = inst->x - pad;
            float iy0 = inst->y - pad;
            float ix1 = inst->x + inst->w + pad;
            float iy1 = inst->y + inst->h + pad;
            if (ix0 < x0) x0 = ix0;
            if (iy0 < y0) y0 = iy0;
            if (ix1 > x1) x1 = ix1;
            if (iy1 > y1) y1 = iy1;
        }
        it->bbox_x0 = x0;
        it->bbox_y0 = y0;
        it->bbox_x1 = x1;
        it->bbox_y1 = y1;
        return;
    }

    if (it->coord_count < 2) {
        it->bbox_x0 = it->bbox_y0 = it->bbox_x1 = it->bbox_y1 = 0.0f;
        return;
    }

    if (it->type == TKMT_ITEM_TEXT) {
        float tw = 0.0f, th = 0.0f;
        if (scene && scene->atlas && it->text && it->text[0]) {
            tkmt_atlas_measure_text(scene->atlas, it->text, it->font_family,
                                    it->font_size > 0.0f ? it->font_size : 12.0f,
                                    &tw, &th);
        }
        float ox = 0.0f, oy = 0.0f;
        anchor_offset(it->anchor, tw, th, &ox, &oy);
        it->bbox_x0 = it->coords[0] + ox;
        it->bbox_y0 = it->coords[1] + oy;
        it->bbox_x1 = it->bbox_x0 + tw;
        it->bbox_y1 = it->bbox_y0 + th;
        return;
    }

    if (it->type == TKMT_ITEM_IMAGE) {
        float w = (float)it->img_w;
        float h = (float)it->img_h;
        float ox = 0.0f, oy = 0.0f;
        anchor_offset(it->anchor, w, h, &ox, &oy);
        it->bbox_x0 = it->coords[0] + ox;
        it->bbox_y0 = it->coords[1] + oy;
        it->bbox_x1 = it->bbox_x0 + w;
        it->bbox_y1 = it->bbox_y0 + h;
        return;
    }

    if (it->type == TKMT_ITEM_WINDOW) {
        float w = it->win_w;
        float h = it->win_h;
        float ox = 0.0f, oy = 0.0f;
        anchor_offset(it->anchor, w, h, &ox, &oy);
        it->bbox_x0 = it->coords[0] + ox;
        it->bbox_y0 = it->coords[1] + oy;
        it->bbox_x1 = it->bbox_x0 + w;
        it->bbox_y1 = it->bbox_y0 + h;
        return;
    }

    float x0 = FLT_MAX, y0 = FLT_MAX, x1 = -FLT_MAX, y1 = -FLT_MAX;
    for (uint32_t i = 0; i + 1 < it->coord_count; i += 2) {
        float x = it->coords[i];
        float y = it->coords[i + 1];
        if (x < x0) x0 = x;
        if (y < y0) y0 = y;
        if (x > x1) x1 = x;
        if (y > y1) y1 = y;
    }
    float pad = (it->width > 0.0f) ? (it->width * 0.5f) : 0.0f;
    it->bbox_x0 = x0 - pad;
    it->bbox_y0 = y0 - pad;
    it->bbox_x1 = x1 + pad;
    it->bbox_y1 = y1 + pad;
}

static void item_free_payload(tkmt_scene_item_t *it) {
    free(it->coords);
    free(it->text);
    free(it->font_family);
    free(it->window_path);
    free(it->instances);
    free(it->extra_tags);
    memset(it, 0, sizeof(*it));
    it->z_prev = -1;
    it->z_next = -1;
}

static int32_t id_lookup_slot(const tkmt_scene_t *s, uint32_t id) {
    if (!s || id == 0 || id >= s->id_table_cap) return -1;
    return s->id_to_slot[id];
}

/* -------------------------------------------------------------------------
 * Lifecycle & Viewport / View Transform
 * ------------------------------------------------------------------------- */

tkmt_scene_t *tkmt_scene_create(uint32_t viewport_w, uint32_t viewport_h) {
    tkmt_scene_t *s = (tkmt_scene_t *)calloc(1, sizeof(tkmt_scene_t));
    if (!s) return NULL;

    s->viewport_w     = viewport_w ? viewport_w : 640u;
    s->viewport_h     = viewport_h ? viewport_h : 480u;
    s->clear_color    = tkmt_rgba(255, 255, 255, 255);
    s->do_clear       = 1;
    tkmt_mat3_identity(s->view_matrix);
    s->next_id        = 1u;
    s->z_head         = -1;
    s->z_tail         = -1;
    s->grid_cell_size = 128.0f;
    s->dirty_flags    = TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_VIEW | TKMT_DIRTY_GRID;

    s->grid_heads = (int32_t *)malloc(TKMT_GRID_BUCKETS * sizeof(int32_t));
    if (!s->grid_heads) {
        free(s);
        return NULL;
    }
    for (uint32_t i = 0; i < TKMT_GRID_BUCKETS; i++) {
        s->grid_heads[i] = -1;
    }

    s->atlas = tkmt_atlas_create(1024, 1024);
    tkmt_draw_list_init(&s->draw_list);
    return s;
}

void tkmt_scene_destroy(tkmt_scene_t *s) {
    if (!s) return;

    for (uint32_t i = 0; i < s->item_cap; i++) {
        if (s->items[i].id != 0) {
            item_free_payload(&s->items[i]);
        }
    }
    free(s->items);
    free(s->free_slots);
    free(s->id_to_slot);

    for (uint32_t i = 0; i < s->tag_count; i++) {
        free(s->tag_names[i]);
    }
    free(s->tag_names);

    free(s->grid_heads);
    free(s->grid_nodes);

    free(s->dl_verts);
    free(s->dl_insts);
    free(s->dl_cmds);

    tkmt_atlas_destroy(s->atlas);
    free(s);
}

void tkmt_scene_set_viewport(tkmt_scene_t *s, uint32_t w, uint32_t h) {
    if (!s) return;
    s->viewport_w = w;
    s->viewport_h = h;
    mark_dirty(s, TKMT_DIRTY_VIEW);
}

void tkmt_scene_get_viewport(const tkmt_scene_t *s, uint32_t *out_w, uint32_t *out_h) {
    if (!s) return;
    if (out_w) *out_w = s->viewport_w;
    if (out_h) *out_h = s->viewport_h;
}

void tkmt_scene_set_clear_color(tkmt_scene_t *s, uint32_t rgba, int do_clear) {
    if (!s) return;
    s->clear_color           = rgba;
    s->do_clear              = do_clear ? 1 : 0;
    s->draw_list.clear_color = s->clear_color;
    s->draw_list.do_clear    = s->do_clear;
    mark_dirty(s, TKMT_DIRTY_VIEW);
}

void tkmt_scene_batch_begin(tkmt_scene_t *s) {
    if (s) s->batch_depth++;
}

void tkmt_scene_batch_end(tkmt_scene_t *s) {
    if (s && s->batch_depth > 0) s->batch_depth--;
}

int tkmt_scene_batch_depth(const tkmt_scene_t *s) {
    return s ? s->batch_depth : 0;
}

void tkmt_scene_set_view_matrix(tkmt_scene_t *s, const float m[9]) {
    if (!s || !m) return;
    memcpy(s->view_matrix, m, sizeof(float) * 9);
    /* Only view transform is dirty; zero re-tessellation */
    mark_dirty(s, TKMT_DIRTY_VIEW);
}

void tkmt_scene_get_view_matrix(const tkmt_scene_t *s, float out_m[9]) {
    if (!s || !out_m) return;
    memcpy(out_m, s->view_matrix, sizeof(float) * 9);
}

void tkmt_scene_set_pan_zoom(tkmt_scene_t *s, float tx, float ty, float sx, float sy) {
    if (!s) return;
    s->view_matrix[0] = sx;   s->view_matrix[1] = 0.0f; s->view_matrix[2] = tx;
    s->view_matrix[3] = 0.0f; s->view_matrix[4] = sy;   s->view_matrix[5] = ty;
    s->view_matrix[6] = 0.0f; s->view_matrix[7] = 0.0f; s->view_matrix[8] = 1.0f;
    mark_dirty(s, TKMT_DIRTY_VIEW);
}

void tkmt_scene_pan(tkmt_scene_t *s, float dx, float dy) {
    if (!s) return;
    s->view_matrix[2] += dx;
    s->view_matrix[5] += dy;
    mark_dirty(s, TKMT_DIRTY_VIEW);
}

void tkmt_scene_zoom(tkmt_scene_t *s, float factor, float cx, float cy) {
    if (!s || factor <= 0.0f) return;
    /* Premultiply by translate(cx,cy) * scale(factor) * translate(-cx,-cy) */
    s->view_matrix[0] *= factor;
    s->view_matrix[1] *= factor;
    s->view_matrix[2]  = factor * (s->view_matrix[2] - cx) + cx;
    s->view_matrix[3] *= factor;
    s->view_matrix[4] *= factor;
    s->view_matrix[5]  = factor * (s->view_matrix[5] - cy) + cy;
    mark_dirty(s, TKMT_DIRTY_VIEW);
}

/* -------------------------------------------------------------------------
 * Item Allocation, Creation & Deletion
 * ------------------------------------------------------------------------- */

static int32_t alloc_slot(tkmt_scene_t *s) {
    if (s->free_count > 0) {
        return s->free_slots[--s->free_count];
    }
    uint32_t new_slot = s->item_count;
    if (new_slot >= s->item_cap) {
        uint32_t ncap = s->item_cap ? s->item_cap * 2u : 64u;
        tkmt_scene_item_t *ni = (tkmt_scene_item_t *)realloc(
            s->items, (size_t)ncap * sizeof(tkmt_scene_item_t));
        if (!ni) return -1;
        memset(ni + s->item_cap, 0, (size_t)(ncap - s->item_cap) * sizeof(tkmt_scene_item_t));
        for (uint32_t i = s->item_cap; i < ncap; i++) {
            ni[i].z_prev = -1;
            ni[i].z_next = -1;
        }
        s->items    = ni;
        s->item_cap = ncap;
    }
    return (int32_t)new_slot;
}

static int ensure_id_table(tkmt_scene_t *s, uint32_t id) {
    if (id < s->id_table_cap) return 1;
    uint32_t ncap = s->id_table_cap ? s->id_table_cap * 2u : 128u;
    while (ncap <= id) ncap *= 2u;
    int32_t *nt = (int32_t *)realloc(s->id_to_slot, (size_t)ncap * sizeof(int32_t));
    if (!nt) return 0;
    for (uint32_t i = s->id_table_cap; i < ncap; i++) {
        nt[i] = -1;
    }
    s->id_to_slot   = nt;
    s->id_table_cap = ncap;
    return 1;
}

static void z_link_tail(tkmt_scene_t *s, int32_t slot) {
    tkmt_scene_item_t *it = &s->items[slot];
    it->z_prev = s->z_tail;
    it->z_next = -1;
    if (s->z_tail != -1) {
        s->items[s->z_tail].z_next = slot;
    } else {
        s->z_head = slot;
    }
    s->z_tail = slot;
}

static void z_unlink(tkmt_scene_t *s, int32_t slot) {
    tkmt_scene_item_t *it = &s->items[slot];
    if (it->z_prev != -1) {
        s->items[it->z_prev].z_next = it->z_next;
    } else {
        s->z_head = it->z_next;
    }
    if (it->z_next != -1) {
        s->items[it->z_next].z_prev = it->z_prev;
    } else {
        s->z_tail = it->z_prev;
    }
    it->z_prev = -1;
    it->z_next = -1;
}

uint32_t tkmt_scene_create_item(tkmt_scene_t *s,
                                tkmt_item_type_t type,
                                const float *coords,
                                uint32_t coord_count) {
    if (!s || type == TKMT_ITEM_NONE) return 0;

    uint32_t id = s->next_id;
    if (!ensure_id_table(s, id)) return 0;
    int32_t slot = alloc_slot(s);
    if (slot < 0) return 0;

    s->next_id++;
    s->item_count++;
    s->id_to_slot[id] = slot;

    tkmt_scene_item_t *it = &s->items[slot];
    memset(it, 0, sizeof(*it));
    it->id            = id;
    it->type          = type;
    it->state         = TKMT_STATE_NORMAL;
    it->flags         = TKMT_ITEM_FLAG_AA;
    it->z_prev        = -1;
    it->z_next        = -1;
    it->width         = 1.0f;
    it->start_deg     = 0.0f;
    it->extent_deg    = 90.0f;
    it->cap_style     = TKMT_CAP_BUTT;
    it->join_style    = TKMT_JOIN_MITER;
    it->arc_style     = TKMT_ARC_PIESLICE;
    it->anchor        = TKMT_ANCHOR_CENTER;
    it->font_size     = 12.0f;

    /* Standard Tk defaults */
    if (type == TKMT_ITEM_LINE || type == TKMT_ITEM_TEXT) {
        it->fill_color    = tkmt_rgba(0, 0, 0, 255);
        it->outline_color = 0;
    } else if (type == TKMT_ITEM_POLYGON) {
        it->fill_color    = tkmt_rgba(0, 0, 0, 255);
        it->outline_color = 0;
    } else {
        it->fill_color    = 0;
        it->outline_color = tkmt_rgba(0, 0, 0, 255);
    }

    if (coords && coord_count > 0) {
        it->coords = (float *)malloc((size_t)coord_count * sizeof(float));
        if (it->coords) {
            memcpy(it->coords, coords, (size_t)coord_count * sizeof(float));
            it->coord_count = coord_count;
            it->coord_cap   = coord_count;
        }
    }

    z_link_tail(s, slot);
    tkmt_scene_recompute_item_bbox(s, it);
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return id;
}

uint32_t tkmt_scene_create_lines_batch(tkmt_scene_t *s,
                                       const float *xy_pairs,
                                       uint32_t segment_count,
                                       uint32_t color,
                                       float width,
                                       uint32_t *out_ids) {
    if (!s || !xy_pairs || segment_count == 0) return 0;

    tkmt_scene_batch_begin(s);
    uint32_t created = 0;
    for (uint32_t i = 0; i < segment_count; i++) {
        const float *c = xy_pairs + (size_t)i * 4u;
        uint32_t id = tkmt_scene_create_item(s, TKMT_ITEM_LINE, c, 4);
        if (id == 0) break;
        tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
        if (it) {
            it->fill_color = color;
            it->width      = width > 0.0f ? width : 1.0f;
            tkmt_scene_recompute_item_bbox(s, it);
        }
        if (out_ids) out_ids[created] = id;
        created++;
    }
    tkmt_scene_batch_end(s);
    return created;
}

uint32_t tkmt_scene_create_instances(tkmt_scene_t *s,
                                     const tkmt_instance_t *instances,
                                     uint32_t count) {
    if (!s) return 0;
    uint32_t id = tkmt_scene_create_item(s, TKMT_ITEM_INSTANCE_BATCH, NULL, 0);
    if (id == 0) return 0;

    if (instances && count > 0) {
        tkmt_scene_update_instances(s, id, instances, count);
    }
    return id;
}

int tkmt_scene_delete_item(tkmt_scene_t *s, uint32_t id) {
    int32_t slot = id_lookup_slot(s, id);
    if (slot < 0) return 0;

    z_unlink(s, slot);
    item_free_payload(&s->items[slot]);
    s->id_to_slot[id] = -1;
    s->item_count--;

    if (s->free_count == s->free_cap) {
        uint32_t ncap = s->free_cap ? s->free_cap * 2u : 64u;
        int32_t *nf   = (int32_t *)realloc(s->free_slots, (size_t)ncap * sizeof(int32_t));
        if (nf) {
            s->free_slots = nf;
            s->free_cap   = ncap;
        }
    }
    if (s->free_count < s->free_cap) {
        s->free_slots[s->free_count++] = slot;
    }

    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

uint32_t tkmt_scene_delete_by_tag(tkmt_scene_t *s, const char *tag_or_id) {
    if (!s || !tag_or_id) return 0;
    if (strcmp(tag_or_id, "all") == 0) {
        uint32_t n = s->item_count;
        tkmt_scene_clear(s);
        return n;
    }

    uint32_t count = tkmt_scene_find_withtag(s, tag_or_id, NULL, 0);
    if (count == 0) return 0;

    uint32_t *ids = (uint32_t *)malloc((size_t)count * sizeof(uint32_t));
    if (!ids) return 0;
    tkmt_scene_find_withtag(s, tag_or_id, ids, count);

    uint32_t deleted = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (tkmt_scene_delete_item(s, ids[i])) deleted++;
    }
    free(ids);
    return deleted;
}

void tkmt_scene_clear(tkmt_scene_t *s) {
    if (!s) return;
    for (uint32_t i = 0; i < s->item_cap; i++) {
        if (s->items[i].id != 0) {
            uint32_t id = s->items[i].id;
            if (id < s->id_table_cap) s->id_to_slot[id] = -1;
            item_free_payload(&s->items[i]);
        }
    }
    s->item_count = 0;
    s->free_count = 0;
    s->z_head     = -1;
    s->z_tail     = -1;
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
}

tkmt_scene_item_t *tkmt_scene_get_item(tkmt_scene_t *s, uint32_t id) {
    int32_t slot = id_lookup_slot(s, id);
    return (slot >= 0) ? &s->items[slot] : NULL;
}

const tkmt_scene_item_t *tkmt_scene_get_item_const(const tkmt_scene_t *s, uint32_t id) {
    int32_t slot = id_lookup_slot(s, id);
    return (slot >= 0) ? &s->items[slot] : NULL;
}

/* -------------------------------------------------------------------------
 * Item Mutators
 * ------------------------------------------------------------------------- */

int tkmt_scene_set_coords(tkmt_scene_t *s, uint32_t id,
                          const float *coords, uint32_t coord_count) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;

    if (coord_count > it->coord_cap) {
        float *nc = (float *)realloc(it->coords, (size_t)coord_count * sizeof(float));
        if (!nc) return 0;
        it->coords    = nc;
        it->coord_cap = coord_count;
    }
    if (coord_count > 0 && coords) {
        memcpy(it->coords, coords, (size_t)coord_count * sizeof(float));
    }
    it->coord_count = coord_count;
    tkmt_scene_recompute_item_bbox(s, it);
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

int tkmt_scene_set_coords_double(tkmt_scene_t *s, uint32_t id,
                                 const double *coords, uint32_t coord_count) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;

    if (coord_count > it->coord_cap) {
        float *nc = (float *)realloc(it->coords, (size_t)coord_count * sizeof(float));
        if (!nc) return 0;
        it->coords    = nc;
        it->coord_cap = coord_count;
    }
    for (uint32_t i = 0; i < coord_count; i++) {
        it->coords[i] = (float)coords[i];
    }
    it->coord_count = coord_count;
    tkmt_scene_recompute_item_bbox(s, it);
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

int tkmt_scene_set_fill(tkmt_scene_t *s, uint32_t id, uint32_t rgba) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->fill_color = rgba;
    mark_dirty(s, TKMT_DIRTY_GEOMETRY);
    return 1;
}

int tkmt_scene_set_outline(tkmt_scene_t *s, uint32_t id, uint32_t rgba) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->outline_color = rgba;
    mark_dirty(s, TKMT_DIRTY_GEOMETRY);
    return 1;
}

int tkmt_scene_set_width(tkmt_scene_t *s, uint32_t id, float width) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->width = width >= 0.0f ? width : 0.0f;
    tkmt_scene_recompute_item_bbox(s, it);
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

int tkmt_scene_set_corner_radius(tkmt_scene_t *s, uint32_t id, float radius) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->corner_radius = radius >= 0.0f ? radius : 0.0f;
    mark_dirty(s, TKMT_DIRTY_GEOMETRY);
    return 1;
}

int tkmt_scene_set_arc_angles(tkmt_scene_t *s, uint32_t id,
                              float start_deg, float extent_deg,
                              tkmt_arc_style_t style) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->start_deg  = start_deg;
    it->extent_deg = extent_deg;
    it->arc_style  = style;
    mark_dirty(s, TKMT_DIRTY_GEOMETRY);
    return 1;
}

int tkmt_scene_set_line_style(tkmt_scene_t *s, uint32_t id,
                              tkmt_cap_style_t cap, tkmt_join_style_t join,
                              const float *dash, uint8_t dash_count, float dash_offset) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->cap_style   = cap;
    it->join_style  = join;
    it->dash_offset = dash_offset;
    if (dash && dash_count > 0) {
        if (dash_count > TKMT_MAX_DASH) dash_count = TKMT_MAX_DASH;
        memcpy(it->dash, dash, (size_t)dash_count * sizeof(float));
        it->dash_count = dash_count;
    } else {
        it->dash_count = 0;
    }
    mark_dirty(s, TKMT_DIRTY_GEOMETRY);
    return 1;
}

int tkmt_scene_set_state(tkmt_scene_t *s, uint32_t id, tkmt_item_state_t state) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->state = state;
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

int tkmt_scene_set_flags(tkmt_scene_t *s, uint32_t id, uint32_t flags) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->flags = flags;
    mark_dirty(s, TKMT_DIRTY_GEOMETRY);
    return 1;
}

int tkmt_scene_set_anchor(tkmt_scene_t *s, uint32_t id, tkmt_anchor_t anchor) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->anchor = anchor;
    tkmt_scene_recompute_item_bbox(s, it);
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

int tkmt_scene_set_text(tkmt_scene_t *s, uint32_t id,
                        const char *text, const char *font_family, float font_size) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    if (text) {
        free(it->text);
        it->text = xstrdup(text);
    }
    if (font_family) {
        free(it->font_family);
        it->font_family = xstrdup(font_family);
    }
    if (font_size > 0.0f) {
        it->font_size = font_size;
    }
    tkmt_scene_recompute_item_bbox(s, it);
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

int tkmt_scene_set_image(tkmt_scene_t *s, uint32_t id,
                         tkmt_tex_id_t tex_id, uint32_t img_w, uint32_t img_h) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    it->tex_id = tex_id;
    it->img_w  = img_w;
    it->img_h  = img_h;
    tkmt_scene_recompute_item_bbox(s, it);
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

int tkmt_scene_set_window(tkmt_scene_t *s, uint32_t id,
                          const char *window_path, float w, float h) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;
    if (window_path) {
        free(it->window_path);
        it->window_path = xstrdup(window_path);
    }
    it->win_w = w;
    it->win_h = h;
    tkmt_scene_recompute_item_bbox(s, it);
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

int tkmt_scene_update_instances(tkmt_scene_t *s, uint32_t id,
                                const tkmt_instance_t *instances, uint32_t count) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it) return 0;

    if (count > it->inst_cap) {
        tkmt_instance_t *ni = (tkmt_instance_t *)realloc(
            it->instances, (size_t)count * sizeof(tkmt_instance_t));
        if (!ni) return 0;
        it->instances = ni;
        it->inst_cap  = count;
    }
    if (count > 0 && instances) {
        memcpy(it->instances, instances, (size_t)count * sizeof(tkmt_instance_t));
    }
    it->inst_count = count;
    tkmt_scene_recompute_item_bbox(s, it);
    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return 1;
}

/* -------------------------------------------------------------------------
 * Tags (interned bitsets)
 * ------------------------------------------------------------------------- */

static int32_t find_tag_index(const tkmt_scene_t *s, const char *tag) {
    if (!s || !tag) return -1;
    for (uint32_t i = 0; i < s->tag_count; i++) {
        if (strcmp(s->tag_names[i], tag) == 0) {
            return (int32_t)i;
        }
    }
    return -1;
}

uint32_t tkmt_scene_intern_tag(tkmt_scene_t *s, const char *tag) {
    if (!s || !tag || tag[0] == '\0') return UINT32_MAX;
    int32_t existing = find_tag_index(s, tag);
    if (existing >= 0) return (uint32_t)existing;

    if (s->tag_count == s->tag_cap) {
        uint32_t ncap = s->tag_cap ? s->tag_cap * 2u : 32u;
        char **nt = (char **)realloc(s->tag_names, (size_t)ncap * sizeof(char *));
        if (!nt) return UINT32_MAX;
        s->tag_names = nt;
        s->tag_cap   = ncap;
    }
    uint32_t idx = s->tag_count++;
    s->tag_names[idx] = xstrdup(tag);
    return idx;
}

static int item_has_tag_idx(const tkmt_scene_item_t *it, uint32_t tidx) {
    if (tidx < TKMT_TAG_INLINE_MAX) {
        return (it->tag_bits[tidx >> 6] & (1ULL << (tidx & 63u))) != 0;
    }
    for (uint32_t i = 0; i < it->extra_tag_count; i++) {
        if (it->extra_tags[i] == tidx) return 1;
    }
    return 0;
}

int tkmt_scene_add_tag(tkmt_scene_t *s, uint32_t id, const char *tag) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it || !tag || tag[0] == '\0') return 0;

    uint32_t tidx = tkmt_scene_intern_tag(s, tag);
    if (tidx == UINT32_MAX) return 0;

    if (tidx < TKMT_TAG_INLINE_MAX) {
        it->tag_bits[tidx >> 6] |= (1ULL << (tidx & 63u));
        return 1;
    }
    if (item_has_tag_idx(it, tidx)) return 1;
    if (it->extra_tag_count == it->extra_tag_cap) {
        uint32_t ncap = it->extra_tag_cap ? it->extra_tag_cap * 2u : 8u;
        uint32_t *ne  = (uint32_t *)realloc(it->extra_tags, (size_t)ncap * sizeof(uint32_t));
        if (!ne) return 0;
        it->extra_tags    = ne;
        it->extra_tag_cap = ncap;
    }
    it->extra_tags[it->extra_tag_count++] = tidx;
    return 1;
}

int tkmt_scene_remove_tag(tkmt_scene_t *s, uint32_t id, const char *tag) {
    tkmt_scene_item_t *it = tkmt_scene_get_item(s, id);
    if (!it || !tag) return 0;

    int32_t tidx = find_tag_index(s, tag);
    if (tidx < 0) return 0;

    uint32_t u = (uint32_t)tidx;
    if (u < TKMT_TAG_INLINE_MAX) {
        it->tag_bits[u >> 6] &= ~(1ULL << (u & 63u));
        return 1;
    }
    for (uint32_t i = 0; i < it->extra_tag_count; i++) {
        if (it->extra_tags[i] == u) {
            it->extra_tags[i] = it->extra_tags[--it->extra_tag_count];
            return 1;
        }
    }
    return 0;
}

int tkmt_scene_has_tag(const tkmt_scene_t *s, uint32_t id, const char *tag) {
    const tkmt_scene_item_t *it = tkmt_scene_get_item_const(s, id);
    if (!it || !tag) return 0;
    if (strcmp(tag, "all") == 0) return 1;
    int32_t tidx = find_tag_index(s, tag);
    if (tidx < 0) return 0;
    return item_has_tag_idx(it, (uint32_t)tidx);
}

uint32_t tkmt_scene_get_tags(const tkmt_scene_t *s, uint32_t id,
                             const char **out_tags, uint32_t max_tags) {
    const tkmt_scene_item_t *it = tkmt_scene_get_item_const(s, id);
    if (!it) return 0;

    uint32_t count = 0;
    uint32_t max_inline = s->tag_count < TKMT_TAG_INLINE_MAX ? s->tag_count : TKMT_TAG_INLINE_MAX;
    for (uint32_t i = 0; i < max_inline; i++) {
        if (it->tag_bits[i >> 6] & (1ULL << (i & 63u))) {
            if (out_tags && count < max_tags) out_tags[count] = s->tag_names[i];
            count++;
        }
    }
    for (uint32_t i = 0; i < it->extra_tag_count; i++) {
        uint32_t tidx = it->extra_tags[i];
        if (tidx < s->tag_count) {
            if (out_tags && count < max_tags) out_tags[count] = s->tag_names[tidx];
            count++;
        }
    }
    return count;
}

static int parse_numeric_id(const char *str, uint32_t *out_id) {
    if (!str || !isdigit((unsigned char)str[0])) return 0;
    char *end = NULL;
    unsigned long v = strtoul(str, &end, 10);
    if (end && *end == '\0' && v > 0 && v <= UINT32_MAX) {
        *out_id = (uint32_t)v;
        return 1;
    }
    return 0;
}

/* -------------------------------------------------------------------------
 * Move, Scale, Raise, Lower
 * ------------------------------------------------------------------------- */

int tkmt_scene_move(tkmt_scene_t *s, const char *tag_or_id, float dx, float dy) {
    if (!s || !tag_or_id) return 0;

    uint32_t count = tkmt_scene_find_withtag(s, tag_or_id, NULL, 0);
    if (count == 0) return 0;

    uint32_t *ids = (uint32_t *)malloc((size_t)count * sizeof(uint32_t));
    if (!ids) return 0;
    tkmt_scene_find_withtag(s, tag_or_id, ids, count);

    for (uint32_t i = 0; i < count; i++) {
        tkmt_scene_item_t *it = tkmt_scene_get_item(s, ids[i]);
        if (!it) continue;
        if (it->type == TKMT_ITEM_INSTANCE_BATCH) {
            for (uint32_t j = 0; j < it->inst_count; j++) {
                it->instances[j].x += dx;
                it->instances[j].y += dy;
            }
        } else {
            for (uint32_t j = 0; j + 1 < it->coord_count; j += 2) {
                it->coords[j]     += dx;
                it->coords[j + 1] += dy;
            }
        }
        it->bbox_x0 += dx;
        it->bbox_y0 += dy;
        it->bbox_x1 += dx;
        it->bbox_y1 += dy;
    }
    free(ids);

    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return (int)count;
}

int tkmt_scene_scale(tkmt_scene_t *s, const char *tag_or_id,
                     float ox, float oy, float sx, float sy) {
    if (!s || !tag_or_id) return 0;

    uint32_t count = tkmt_scene_find_withtag(s, tag_or_id, NULL, 0);
    if (count == 0) return 0;

    uint32_t *ids = (uint32_t *)malloc((size_t)count * sizeof(uint32_t));
    if (!ids) return 0;
    tkmt_scene_find_withtag(s, tag_or_id, ids, count);

    for (uint32_t i = 0; i < count; i++) {
        tkmt_scene_item_t *it = tkmt_scene_get_item(s, ids[i]);
        if (!it) continue;
        if (it->type == TKMT_ITEM_INSTANCE_BATCH) {
            for (uint32_t j = 0; j < it->inst_count; j++) {
                it->instances[j].x = ox + (it->instances[j].x - ox) * sx;
                it->instances[j].y = oy + (it->instances[j].y - oy) * sy;
                it->instances[j].w *= fabsf(sx);
                it->instances[j].h *= fabsf(sy);
            }
        } else {
            for (uint32_t j = 0; j + 1 < it->coord_count; j += 2) {
                it->coords[j]     = ox + (it->coords[j] - ox) * sx;
                it->coords[j + 1] = oy + (it->coords[j + 1] - oy) * sy;
            }
        }
        tkmt_scene_recompute_item_bbox(s, it);
    }
    free(ids);

    mark_dirty(s, TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_GRID);
    return (int)count;
}

int tkmt_scene_raise(tkmt_scene_t *s, uint32_t id, uint32_t above_id) {
    int32_t slot = id_lookup_slot(s, id);
    if (slot < 0) return 0;

    if (above_id == 0) {
        if (slot == s->z_tail) return 1;
        z_unlink(s, slot);
        z_link_tail(s, slot);
    } else {
        int32_t target = id_lookup_slot(s, above_id);
        if (target < 0 || target == slot) return 0;
        z_unlink(s, slot);
        int32_t next = s->items[target].z_next;
        s->items[slot].z_prev   = target;
        s->items[slot].z_next   = next;
        s->items[target].z_next = slot;
        if (next != -1) {
            s->items[next].z_prev = slot;
        } else {
            s->z_tail = slot;
        }
    }
    mark_dirty(s, TKMT_DIRTY_GEOMETRY);
    return 1;
}

int tkmt_scene_lower(tkmt_scene_t *s, uint32_t id, uint32_t below_id) {
    int32_t slot = id_lookup_slot(s, id);
    if (slot < 0) return 0;

    if (below_id == 0) {
        if (slot == s->z_head) return 1;
        z_unlink(s, slot);
        s->items[slot].z_prev = -1;
        s->items[slot].z_next = s->z_head;
        if (s->z_head != -1) {
            s->items[s->z_head].z_prev = slot;
        } else {
            s->z_tail = slot;
        }
        s->z_head = slot;
    } else {
        int32_t target = id_lookup_slot(s, below_id);
        if (target < 0 || target == slot) return 0;
        z_unlink(s, slot);
        int32_t prev = s->items[target].z_prev;
        s->items[slot].z_prev   = prev;
        s->items[slot].z_next   = target;
        s->items[target].z_prev = slot;
        if (prev != -1) {
            s->items[prev].z_next = slot;
        } else {
            s->z_head = slot;
        }
    }
    mark_dirty(s, TKMT_DIRTY_GEOMETRY);
    return 1;
}

/* -------------------------------------------------------------------------
 * Exact Geometry Hit-Testing Helpers
 * ------------------------------------------------------------------------- */

static float dist_point_to_segment(float px, float py,
                                   float x0, float y0, float x1, float y1) {
    float dx = x1 - x0;
    float dy = y1 - y0;
    float len2 = dx * dx + dy * dy;
    if (len2 <= 1e-12f) {
        return hypotf(px - x0, py - y0);
    }
    float t = ((px - x0) * dx + (py - y0) * dy) / len2;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    float cx = x0 + t * dx;
    float cy = y0 + t * dy;
    return hypotf(px - cx, py - cy);
}

static int point_in_polygon(float px, float py, const float *coords, uint32_t coord_count) {
    uint32_t n = coord_count / 2u;
    if (n < 3) return 0;
    int inside = 0;
    for (uint32_t i = 0, j = n - 1; i < n; j = i++) {
        float xi = coords[2 * i],     yi = coords[2 * i + 1];
        float xj = coords[2 * j],     yj = coords[2 * j + 1];
        int intersect = ((yi > py) != (yj > py)) &&
                        (px < (xj - xi) * (py - yi) / ((yj - yi) + 1e-30f) + xi);
        if (intersect) inside = !inside;
    }
    return inside;
}

static float dist_point_to_rect(float px, float py,
                                float x0, float y0, float x1, float y1,
                                int filled) {
    if (x0 > x1) { float t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { float t = y0; y0 = y1; y1 = t; }
    if (filled && px >= x0 && px <= x1 && py >= y0 && py <= y1) {
        return 0.0f;
    }
    if (px >= x0 && px <= x1 && py >= y0 && py <= y1) {
        float d = minf(minf(px - x0, x1 - px), minf(py - y0, y1 - py));
        return d;
    }
    float dx = maxf(maxf(x0 - px, 0.0f), px - x1);
    float dy = maxf(maxf(y0 - py, 0.0f), py - y1);
    return hypotf(dx, dy);
}

static float item_point_distance(const tkmt_scene_item_t *it, float px, float py) {
    if (!it || it->state == TKMT_STATE_HIDDEN) return FLT_MAX;

    float half_w = it->width * 0.5f;
    int has_fill = (tkmt_rgba_a(it->fill_color) > 0);

    switch (it->type) {
        case TKMT_ITEM_LINE: {
            if (it->coord_count < 4) return FLT_MAX;
            float best = FLT_MAX;
            for (uint32_t i = 0; i + 3 < it->coord_count; i += 2) {
                float d = dist_point_to_segment(px, py,
                                                it->coords[i], it->coords[i + 1],
                                                it->coords[i + 2], it->coords[i + 3]);
                if (d < best) best = d;
            }
            return maxf(0.0f, best - half_w);
        }

        case TKMT_ITEM_RECTANGLE: {
            if (it->coord_count < 4) return FLT_MAX;
            float d = dist_point_to_rect(px, py,
                                         it->coords[0], it->coords[1],
                                         it->coords[2], it->coords[3], has_fill);
            return maxf(0.0f, d - half_w);
        }

        case TKMT_ITEM_OVAL:
        case TKMT_ITEM_ARC: {
            if (it->coord_count < 4) return FLT_MAX;
            float x0 = minf(it->coords[0], it->coords[2]);
            float y0 = minf(it->coords[1], it->coords[3]);
            float x1 = maxf(it->coords[0], it->coords[2]);
            float y1 = maxf(it->coords[1], it->coords[3]);
            float rx = (x1 - x0) * 0.5f;
            float ry = (y1 - y0) * 0.5f;
            if (rx <= 1e-5f || ry <= 1e-5f) {
                return dist_point_to_rect(px, py, x0, y0, x1, y1, 1);
            }
            float cx = (x0 + x1) * 0.5f;
            float cy = (y0 + y1) * 0.5f;
            float nx = (px - cx) / rx;
            float ny = (py - cy) / ry;
            float r  = hypotf(nx, ny);
            float avg_r = 0.5f * (rx + ry);
            if (has_fill && r <= 1.0f) return 0.0f;
            float d = fabsf(r - 1.0f) * avg_r;
            return maxf(0.0f, d - half_w);
        }

        case TKMT_ITEM_POLYGON: {
            if (it->coord_count < 6) return FLT_MAX;
            if (has_fill && point_in_polygon(px, py, it->coords, it->coord_count)) {
                return 0.0f;
            }
            uint32_t n = it->coord_count / 2u;
            float best = FLT_MAX;
            for (uint32_t i = 0; i < n; i++) {
                uint32_t j = (i + 1u) % n;
                float d = dist_point_to_segment(px, py,
                                                it->coords[2 * i], it->coords[2 * i + 1],
                                                it->coords[2 * j], it->coords[2 * j + 1]);
                if (d < best) best = d;
            }
            return maxf(0.0f, best - half_w);
        }

        case TKMT_ITEM_TEXT:
        case TKMT_ITEM_IMAGE:
        case TKMT_ITEM_WINDOW:
        case TKMT_ITEM_INSTANCE_BATCH:
        default:
            return dist_point_to_rect(px, py,
                                      it->bbox_x0, it->bbox_y0,
                                      it->bbox_x1, it->bbox_y1, 1);
    }
}

/* -------------------------------------------------------------------------
 * Spatial Queries & Bounding Box
 * ------------------------------------------------------------------------- */

uint32_t tkmt_scene_find_all(const tkmt_scene_t *s,
                             uint32_t *out_ids, uint32_t max_ids) {
    if (!s) return 0;
    uint32_t count = 0;
    for (int32_t slot = s->z_head; slot != -1; slot = s->items[slot].z_next) {
        if (out_ids && count < max_ids) out_ids[count] = s->items[slot].id;
        count++;
    }
    return count;
}

uint32_t tkmt_scene_find_withtag(const tkmt_scene_t *s, const char *tag_or_id,
                                 uint32_t *out_ids, uint32_t max_ids) {
    if (!s || !tag_or_id) return 0;
    if (strcmp(tag_or_id, "all") == 0) {
        return tkmt_scene_find_all(s, out_ids, max_ids);
    }

    uint32_t num_id = 0;
    if (parse_numeric_id(tag_or_id, &num_id)) {
        int32_t slot = id_lookup_slot(s, num_id);
        if (slot >= 0) {
            if (out_ids && max_ids > 0) out_ids[0] = num_id;
            return 1;
        }
        return 0;
    }

    int32_t tidx = find_tag_index(s, tag_or_id);
    if (tidx < 0) return 0;

    uint32_t count = 0;
    for (int32_t slot = s->z_head; slot != -1; slot = s->items[slot].z_next) {
        const tkmt_scene_item_t *it = &s->items[slot];
        if (item_has_tag_idx(it, (uint32_t)tidx)) {
            if (out_ids && count < max_ids) out_ids[count] = it->id;
            count++;
        }
    }
    return count;
}

static void collect_grid_candidates(tkmt_scene_t *s,
                                    float x0, float y0, float x1, float y1,
                                    int enclosed_only,
                                    uint32_t *out_count,
                                    uint32_t *out_ids,
                                    uint32_t max_ids) {
    if (x0 > x1) { float t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { float t = y0; y0 = y1; y1 = t; }

    grid_ensure_fresh(s);
    s->visit_gen++;
    if (s->visit_gen == 0) {
        for (uint32_t i = 0; i < s->item_cap; i++) s->items[i].visit_gen = 0;
        s->visit_gen = 1;
    }
    uint32_t gen = s->visit_gen;

    float inv = 1.0f / s->grid_cell_size;
    int32_t cx0 = (int32_t)floorf(x0 * inv);
    int32_t cy0 = (int32_t)floorf(y0 * inv);
    int32_t cx1 = (int32_t)floorf(x1 * inv);
    int32_t cy1 = (int32_t)floorf(y1 * inv);

    int64_t span_x = (int64_t)cx1 - (int64_t)cx0 + 1;
    int64_t span_y = (int64_t)cy1 - (int64_t)cy0 + 1;

    /* If query rect spans too many cells, scan z-order directly (faster & exact) */
    if (span_x * span_y > 1024) {
        uint32_t count = 0;
        for (int32_t slot = s->z_head; slot != -1; slot = s->items[slot].z_next) {
            const tkmt_scene_item_t *it = &s->items[slot];
            if (it->state == TKMT_STATE_HIDDEN) continue;
            int hit = enclosed_only
                ? (it->bbox_x0 >= x0 && it->bbox_x1 <= x1 &&
                   it->bbox_y0 >= y0 && it->bbox_y1 <= y1)
                : (it->bbox_x1 >= x0 && it->bbox_x0 <= x1 &&
                   it->bbox_y1 >= y0 && it->bbox_y0 <= y1);
            if (hit) {
                if (out_ids && count < max_ids) out_ids[count] = it->id;
                count++;
            }
        }
        *out_count = count;
        return;
    }

    /* Mark matching slots via grid buckets */
    uint32_t hit_count = 0;
    for (int32_t cy = cy0; cy <= cy1; cy++) {
        for (int32_t cx = cx0; cx <= cx1; cx++) {
            uint32_t b = grid_hash(cx, cy);
            for (int32_t ni = s->grid_heads[b]; ni != -1; ni = s->grid_nodes[ni].next) {
                const tkmt_grid_node_t *gn = &s->grid_nodes[ni];
                if (gn->cx != cx || gn->cy != cy) continue;
                tkmt_scene_item_t *it = &s->items[gn->slot];
                if (it->visit_gen == gen || it->state == TKMT_STATE_HIDDEN) continue;
                int hit = enclosed_only
                    ? (it->bbox_x0 >= x0 && it->bbox_x1 <= x1 &&
                       it->bbox_y0 >= y0 && it->bbox_y1 <= y1)
                    : (it->bbox_x1 >= x0 && it->bbox_x0 <= x1 &&
                       it->bbox_y1 >= y0 && it->bbox_y0 <= y1);
                if (hit) {
                    it->visit_gen = gen;
                    hit_count++;
                }
            }
        }
    }

    /* Also check oversized-item sentinel bucket */
    {
        uint32_t b = grid_hash(INT32_MAX, INT32_MAX);
        for (int32_t ni = s->grid_heads[b]; ni != -1; ni = s->grid_nodes[ni].next) {
            const tkmt_grid_node_t *gn = &s->grid_nodes[ni];
            if (gn->cx != INT32_MAX || gn->cy != INT32_MAX) continue;
            tkmt_scene_item_t *it = &s->items[gn->slot];
            if (it->visit_gen == gen || it->state == TKMT_STATE_HIDDEN) continue;
            int hit = enclosed_only
                ? (it->bbox_x0 >= x0 && it->bbox_x1 <= x1 &&
                   it->bbox_y0 >= y0 && it->bbox_y1 <= y1)
                : (it->bbox_x1 >= x0 && it->bbox_x0 <= x1 &&
                   it->bbox_y1 >= y0 && it->bbox_y0 <= y1);
            if (hit) {
                it->visit_gen = gen;
                hit_count++;
            }
        }
    }

    if (hit_count == 0) {
        *out_count = 0;
        return;
    }

    if (!out_ids || max_ids == 0) {
        *out_count = hit_count;
        return;
    }

    /* Emit in z-order (Tk Canvas contract) */
    uint32_t written = 0;
    for (int32_t slot = s->z_head; slot != -1 && written < hit_count; slot = s->items[slot].z_next) {
        if (s->items[slot].visit_gen == gen) {
            if (written < max_ids) out_ids[written] = s->items[slot].id;
            written++;
        }
    }
    *out_count = written;
}

uint32_t tkmt_scene_find_overlapping(tkmt_scene_t *s,
                                     float x0, float y0, float x1, float y1,
                                     uint32_t *out_ids, uint32_t max_ids) {
    if (!s) return 0;
    uint32_t count = 0;
    collect_grid_candidates(s, x0, y0, x1, y1, 0, &count, out_ids, max_ids);
    return count;
}

uint32_t tkmt_scene_find_enclosed(tkmt_scene_t *s,
                                  float x0, float y0, float x1, float y1,
                                  uint32_t *out_ids, uint32_t max_ids) {
    if (!s) return 0;
    uint32_t count = 0;
    collect_grid_candidates(s, x0, y0, x1, y1, 1, &count, out_ids, max_ids);
    return count;
}

uint32_t tkmt_scene_find_closest(tkmt_scene_t *s, float x, float y, float halo) {
    if (!s || s->item_count == 0) return 0;
    if (halo < 0.0f) halo = 0.0f;

    /* Traverse top-to-bottom (z_tail -> z_head) so topmost item wins ties
     * and any item within halo wins immediately if at distance <= halo. */
    uint32_t best_id   = 0;
    float    best_dist = FLT_MAX;

    for (int32_t slot = s->z_tail; slot != -1; slot = s->items[slot].z_prev) {
        const tkmt_scene_item_t *it = &s->items[slot];
        if (it->state == TKMT_STATE_HIDDEN) continue;

        /* Quick bbox lower-bound reject */
        float bx = maxf(maxf(it->bbox_x0 - x, 0.0f), x - it->bbox_x1);
        float by = maxf(maxf(it->bbox_y0 - y, 0.0f), y - it->bbox_y1);
        float bbox_d = hypotf(bx, by);
        if (bbox_d > best_dist && bbox_d > halo) continue;

        float d = item_point_distance(it, x, y);
        if (d <= halo) {
            return it->id; /* Topmost item within halo */
        }
        if (d < best_dist) {
            best_dist = d;
            best_id   = it->id;
        }
    }
    return best_id;
}

int tkmt_scene_bbox(const tkmt_scene_t *s, const char *tag_or_id, float out_bbox[4]) {
    if (!s || !out_bbox) return 0;

    int all = (!tag_or_id || tag_or_id[0] == '\0' || strcmp(tag_or_id, "all") == 0);
    uint32_t num_id = 0;
    int is_num = (!all && parse_numeric_id(tag_or_id, &num_id));
    int32_t tidx = (!all && !is_num) ? find_tag_index(s, tag_or_id) : -1;

    if (!all && !is_num && tidx < 0) return 0;

    float x0 = FLT_MAX, y0 = FLT_MAX, x1 = -FLT_MAX, y1 = -FLT_MAX;
    int found = 0;

    if (is_num) {
        const tkmt_scene_item_t *it = tkmt_scene_get_item_const(s, num_id);
        if (!it || it->state == TKMT_STATE_HIDDEN) return 0;
        out_bbox[0] = it->bbox_x0;
        out_bbox[1] = it->bbox_y0;
        out_bbox[2] = it->bbox_x1;
        out_bbox[3] = it->bbox_y1;
        return 1;
    }

    for (int32_t slot = s->z_head; slot != -1; slot = s->items[slot].z_next) {
        const tkmt_scene_item_t *it = &s->items[slot];
        if (it->state == TKMT_STATE_HIDDEN) continue;
        if (!all && !item_has_tag_idx(it, (uint32_t)tidx)) continue;
        if (it->bbox_x0 < x0) x0 = it->bbox_x0;
        if (it->bbox_y0 < y0) y0 = it->bbox_y0;
        if (it->bbox_x1 > x1) x1 = it->bbox_x1;
        if (it->bbox_y1 > y1) y1 = it->bbox_y1;
        found = 1;
    }

    if (!found) return 0;
    out_bbox[0] = x0;
    out_bbox[1] = y0;
    out_bbox[2] = x1;
    out_bbox[3] = y1;
    return 1;
}

tkmt_atlas_t *tkmt_scene_atlas(tkmt_scene_t *s) {
    return s ? s->atlas : NULL;
}

void tkmt_scene_get_stats(const tkmt_scene_t *s, tkmt_scene_stats_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!s) return;

    uint32_t total_inst = 0;
    for (int32_t slot = s->z_head; slot != -1; slot = s->items[slot].z_next) {
        if (s->items[slot].type == TKMT_ITEM_INSTANCE_BATCH) {
            total_inst += s->items[slot].inst_count;
        }
    }

    out->item_count        = s->item_count;
    out->total_instances   = total_inst;
    out->tessellate_count  = s->tessellate_count;
    out->view_only_updates = s->view_only_updates;
    out->grid_rebuilds     = s->grid_rebuilds;
    out->cached_vertices   = s->dl_vert_count;
    out->cached_instances  = s->dl_inst_count;
    out->cached_cmds       = s->dl_cmd_count;
}
