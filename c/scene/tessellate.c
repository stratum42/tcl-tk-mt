/*
 * Tcl::Tk::MT - 2D Scene Tessellator (C11)
 *
 * Converts retained scene items into tkmt_draw_list_t:
 *   - Polylines with width, butt/projecting/round caps, miter/bevel/round joins,
 *     and dash splitting
 *   - Ear-clipping triangulation for arbitrary simple polygons + outline stroke
 *   - SDF instances for rectangles, rounded rects, ovals, arcs, and bulk
 *     instance batches (100k+ shapes via single memcpy)
 *   - Glyph atlas textured quads for text (TKMT_CMD_GLYPHS)
 *   - Textured quads for RGBA8 Photo images (TKMT_CMD_TEXTURED_TRIANGLES)
 *   - Zero re-tessellation on view_matrix (pan/zoom) updates
 */

#include "scene.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static inline float minf(float a, float b) { return a < b ? a : b; }
static inline float maxf(float a, float b) { return a > b ? a : b; }

extern void  tkmt_atlas_set_scale(tkmt_atlas_t *atlas, float scale);
extern float tkmt_atlas_get_scale(const tkmt_atlas_t *atlas);
#ifdef __APPLE__
extern float tkmt_metal_surface_scale(const tkmt_gfx_surface_t *surf);
#endif

/* -------------------------------------------------------------------------
 * Draw-list buffer append & command coalescing
 * ------------------------------------------------------------------------- */

static int dl_reserve_verts(tkmt_scene_t *s, uint32_t extra) {
    uint32_t need = s->dl_vert_count + extra;
    if (need <= s->dl_vert_cap) return 1;
    uint32_t ncap = s->dl_vert_cap ? s->dl_vert_cap * 2u : 1024u;
    while (ncap < need) ncap *= 2u;
    tkmt_vertex_t *nv = (tkmt_vertex_t *)realloc(s->dl_verts, (size_t)ncap * sizeof(tkmt_vertex_t));
    if (!nv) return 0;
    s->dl_verts    = nv;
    s->dl_vert_cap = ncap;
    return 1;
}

static int dl_reserve_insts(tkmt_scene_t *s, uint32_t extra) {
    uint32_t need = s->dl_inst_count + extra;
    if (need <= s->dl_inst_cap) return 1;
    uint32_t ncap = s->dl_inst_cap ? s->dl_inst_cap * 2u : 256u;
    while (ncap < need) ncap *= 2u;
    tkmt_instance_t *ni = (tkmt_instance_t *)realloc(
        s->dl_insts, (size_t)ncap * sizeof(tkmt_instance_t));
    if (!ni) return 0;
    s->dl_insts    = ni;
    s->dl_inst_cap = ncap;
    return 1;
}

static void dl_push_cmd(tkmt_scene_t *s,
                        tkmt_draw_cmd_type_t type,
                        uint32_t first,
                        uint32_t count,
                        tkmt_tex_id_t tex_id,
                        uint32_t flags) {
    if (count == 0) return;

    if (s->dl_cmd_count > 0) {
        tkmt_draw_cmd_t *prev = &s->dl_cmds[s->dl_cmd_count - 1];
        if (prev->type == type &&
            prev->tex_id == tex_id &&
            prev->flags == flags &&
            prev->clip.w <= 0 &&
            prev->first + prev->count == first) {
            prev->count += count;
            return;
        }
    }

    if (s->dl_cmd_count == s->dl_cmd_cap) {
        uint32_t ncap = s->dl_cmd_cap ? s->dl_cmd_cap * 2u : 64u;
        tkmt_draw_cmd_t *nc = (tkmt_draw_cmd_t *)realloc(
            s->dl_cmds, (size_t)ncap * sizeof(tkmt_draw_cmd_t));
        if (!nc) return;
        s->dl_cmds    = nc;
        s->dl_cmd_cap = ncap;
    }

    tkmt_draw_cmd_t *cmd = &s->dl_cmds[s->dl_cmd_count++];
    cmd->type   = type;
    cmd->first  = first;
    cmd->count  = count;
    cmd->tex_id = tex_id;
    cmd->clip.x = 0;
    cmd->clip.y = 0;
    cmd->clip.w = 0;
    cmd->clip.h = 0;
    cmd->flags  = flags;
}

static inline void emit_tri(tkmt_scene_t *s,
                            float x0, float y0,
                            float x1, float y1,
                            float x2, float y2,
                            uint32_t color) {
    if (!dl_reserve_verts(s, 3)) return;
    tkmt_vertex_t *v = &s->dl_verts[s->dl_vert_count];
    v[0].x = x0; v[0].y = y0; v[0].u = 0.0f; v[0].v = 0.0f; v[0].color = color; v[0].flags = 0;
    v[1].x = x1; v[1].y = y1; v[1].u = 0.0f; v[1].v = 0.0f; v[1].color = color; v[1].flags = 0;
    v[2].x = x2; v[2].y = y2; v[2].u = 0.0f; v[2].v = 0.0f; v[2].color = color; v[2].flags = 0;
    s->dl_vert_count += 3;
}

static inline void emit_tex_quad(tkmt_scene_t *s,
                                 float x0, float y0, float x1, float y1,
                                 float u0, float v0, float u1, float v1,
                                 uint32_t color) {
    if (!dl_reserve_verts(s, 6)) return;
    tkmt_vertex_t *v = &s->dl_verts[s->dl_vert_count];
    v[0].x = x0; v[0].y = y0; v[0].u = u0; v[0].v = v0; v[0].color = color; v[0].flags = 0;
    v[1].x = x1; v[1].y = y0; v[1].u = u1; v[1].v = v0; v[1].color = color; v[1].flags = 0;
    v[2].x = x1; v[2].y = y1; v[2].u = u1; v[2].v = v1; v[2].color = color; v[2].flags = 0;
    v[3].x = x0; v[3].y = y0; v[3].u = u0; v[3].v = v0; v[3].color = color; v[3].flags = 0;
    v[4].x = x1; v[4].y = y1; v[4].u = u1; v[4].v = v1; v[4].color = color; v[4].flags = 0;
    v[5].x = x0; v[5].y = y1; v[5].u = u0; v[5].v = v1; v[5].color = color; v[5].flags = 0;
    s->dl_vert_count += 6;
}

static void emit_fan(tkmt_scene_t *s, float cx, float cy, float r,
                     float a0, float a1, int steps, uint32_t color) {
    if (steps < 2) steps = 2;
    float da = (a1 - a0) / (float)steps;
    for (int i = 0; i < steps; i++) {
        float t0 = a0 + da * (float)i;
        float t1 = a0 + da * (float)(i + 1);
        emit_tri(s, cx, cy,
                 cx + cosf(t0) * r, cy + sinf(t0) * r,
                 cx + cosf(t1) * r, cy + sinf(t1) * r,
                 color);
    }
}

/* -------------------------------------------------------------------------
 * Polyline Tessellation (caps, joins, dashes)
 * ------------------------------------------------------------------------- */

static void tessellate_polyline_solid(tkmt_scene_t *s,
                                      const float *pts, uint32_t num_pts,
                                      int closed,
                                      float width,
                                      uint32_t color,
                                      tkmt_cap_style_t cap,
                                      tkmt_join_style_t join,
                                      uint32_t cmd_flags) {
    if (num_pts < 2 || width <= 0.0f || tkmt_rgba_a(color) == 0) return;

    float hw = width * 0.5f;
    uint32_t v_start = s->dl_vert_count;
    uint32_t seg_count = closed ? num_pts : (num_pts - 1u);

    for (uint32_t i = 0; i < seg_count; i++) {
        uint32_t i0 = i;
        uint32_t i1 = (i + 1u) % num_pts;
        float x0 = pts[2 * i0],     y0 = pts[2 * i0 + 1];
        float x1 = pts[2 * i1],     y1 = pts[2 * i1 + 1];
        float dx = x1 - x0;
        float dy = y1 - y0;
        float len = hypotf(dx, dy);
        if (len <= 1e-6f) continue;

        float tx = dx / len;
        float ty = dy / len;
        float nx = -ty * hw;
        float ny =  tx * hw;

        float sx0 = x0, sy0 = y0, sx1 = x1, sy1 = y1;
        if (!closed && cap == TKMT_CAP_PROJECTING) {
            if (i == 0) {
                sx0 -= tx * hw;
                sy0 -= ty * hw;
            }
            if (i == seg_count - 1u) {
                sx1 += tx * hw;
                sy1 += ty * hw;
            }
        }

        /* Segment quad (2 triangles) */
        emit_tri(s, sx0 + nx, sy0 + ny, sx1 + nx, sy1 + ny, sx1 - nx, sy1 - ny, color);
        emit_tri(s, sx0 + nx, sy0 + ny, sx1 - nx, sy1 - ny, sx0 - nx, sy0 - ny, color);

        /* Round caps on open ends */
        if (!closed && cap == TKMT_CAP_ROUND) {
            if (i == 0) {
                float a = atan2f(-ty, -tx);
                emit_fan(s, x0, y0, hw, a - (float)(M_PI * 0.5), a + (float)(M_PI * 0.5), 8, color);
            }
            if (i == seg_count - 1u) {
                float a = atan2f(ty, tx);
                emit_fan(s, x1, y1, hw, a - (float)(M_PI * 0.5), a + (float)(M_PI * 0.5), 8, color);
            }
        }

        /* Join with next segment */
        if (closed || i + 1u < seg_count) {
            uint32_t i2 = (i + 2u) % num_pts;
            float x2 = pts[2 * i2], y2 = pts[2 * i2 + 1];
            float dx2 = x2 - x1, dy2 = y2 - y1;
            float len2 = hypotf(dx2, dy2);
            if (len2 <= 1e-6f) continue;

            float tx2 = dx2 / len2, ty2 = dy2 / len2;
            float nx2 = -ty2 * hw,  ny2 =  tx2 * hw;

            float cross = tx * ty2 - ty * tx2;
            if (fabsf(cross) < 1e-5f) continue;

            /* Outer normal side depends on turn direction */
            float sign = (cross > 0.0f) ? -1.0f : 1.0f;
            float ox1 = sign * nx,  oy1 = sign * ny;
            float ox2 = sign * nx2, oy2 = sign * ny2;

            if (join == TKMT_JOIN_ROUND) {
                float a0 = atan2f(oy1, ox1);
                float a1 = atan2f(oy2, ox2);
                float diff = a1 - a0;
                while (diff >  (float)M_PI) diff -= (float)(2.0 * M_PI);
                while (diff < -(float)M_PI) diff += (float)(2.0 * M_PI);
                emit_fan(s, x1, y1, hw, a0, a0 + diff, 6, color);
            } else if (join == TKMT_JOIN_MITER) {
                /* Compute miter intersection of outer offset lines */
                float mx = ox1 + ox2;
                float my = oy1 + oy2;
                float mlen = hypotf(mx, my);
                float dot = (ox1 * ox2 + oy1 * oy2) / (hw * hw);
                float denom = 1.0f + dot;
                if (mlen > 1e-5f && denom > 0.125f) { /* miter limit ~4x */
                    float scale = (hw * hw * 2.0f) / (denom * mlen);
                    if (scale <= hw * 4.0f) {
                        float px = x1 + (mx / mlen) * scale;
                        float py = y1 + (my / mlen) * scale;
                        emit_tri(s, x1, y1, x1 + ox1, y1 + oy1, px, py, color);
                        emit_tri(s, x1, y1, px, py, x1 + ox2, y1 + oy2, color);
                        continue;
                    }
                }
                /* Fallback to bevel when miter exceeds limit */
                emit_tri(s, x1, y1, x1 + ox1, y1 + oy1, x1 + ox2, y1 + oy2, color);
            } else {
                /* TKMT_JOIN_BEVEL */
                emit_tri(s, x1, y1, x1 + ox1, y1 + oy1, x1 + ox2, y1 + oy2, color);
            }
        }
    }

    uint32_t v_added = s->dl_vert_count - v_start;
    if (v_added > 0) {
        dl_push_cmd(s, TKMT_CMD_TRIANGLES, v_start, v_added, 0, cmd_flags);
    }
}

static void tessellate_polyline_dashed(tkmt_scene_t *s,
                                       const float *pts, uint32_t num_pts,
                                       int closed,
                                       float width,
                                       uint32_t color,
                                       tkmt_cap_style_t cap,
                                       tkmt_join_style_t join,
                                       const float *dash, uint8_t dash_count,
                                       float dash_offset,
                                       uint32_t cmd_flags) {
    if (dash_count == 0) {
        tessellate_polyline_solid(s, pts, num_pts, closed, width, color, cap, join, cmd_flags);
        return;
    }

    /* Validate dash pattern sum */
    float total_pat = 0.0f;
    for (uint8_t i = 0; i < dash_count; i++) {
        if (dash[i] > 0.0f) total_pat += dash[i];
    }
    if (total_pat <= 1e-4f) {
        tessellate_polyline_solid(s, pts, num_pts, closed, width, color, cap, join, cmd_flags);
        return;
    }

    /* Advance to initial dash_offset */
    float off = fmodf(dash_offset, total_pat);
    if (off < 0.0f) off += total_pat;
    uint8_t d_idx = 0;
    int draw_on   = 1;
    while (off > 0.0f) {
        float dlen = dash[d_idx];
        if (dlen <= 0.0f) dlen = 1.0f;
        if (off < dlen) {
            break;
        }
        off -= dlen;
        d_idx = (uint8_t)((d_idx + 1u) % dash_count);
        draw_on = !draw_on;
    }
    float rem = dash[d_idx] - off;
    if (rem <= 0.0f) rem = 1.0f;

    uint32_t seg_count = closed ? num_pts : (num_pts - 1u);
    for (uint32_t i = 0; i < seg_count; i++) {
        uint32_t i0 = i;
        uint32_t i1 = (i + 1u) % num_pts;
        float x0 = pts[2 * i0], y0 = pts[2 * i0 + 1];
        float x1 = pts[2 * i1], y1 = pts[2 * i1 + 1];
        float dx = x1 - x0, dy = y1 - y0;
        float seg_len = hypotf(dx, dy);
        if (seg_len <= 1e-6f) continue;

        float pos = 0.0f;
        while (pos < seg_len) {
            float step = minf(rem, seg_len - pos);
            float t0 = pos / seg_len;
            float t1 = (pos + step) / seg_len;
            if (draw_on && step > 1e-4f) {
                float seg_pts[4] = {
                    x0 + dx * t0, y0 + dy * t0,
                    x0 + dx * t1, y0 + dy * t1
                };
                tessellate_polyline_solid(s, seg_pts, 2, 0, width, color, cap, join, cmd_flags);
            }
            pos += step;
            rem -= step;
            if (rem <= 1e-4f) {
                d_idx = (uint8_t)((d_idx + 1u) % dash_count);
                draw_on = !draw_on;
                rem = dash[d_idx] > 0.0f ? dash[d_idx] : 1.0f;
            }
        }
    }
}

/* -------------------------------------------------------------------------
 * Ear-Clipping Polygon Triangulation
 * ------------------------------------------------------------------------- */

static float tri_cross2(float ax, float ay, float bx, float by, float cx, float cy) {
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
}

static int point_in_tri(float px, float py,
                        float ax, float ay, float bx, float by, float cx, float cy) {
    float c1 = tri_cross2(ax, ay, bx, by, px, py);
    float c2 = tri_cross2(bx, by, cx, cy, px, py);
    float c3 = tri_cross2(cx, cy, ax, ay, px, py);
    int has_neg = (c1 < 0.0f) || (c2 < 0.0f) || (c3 < 0.0f);
    int has_pos = (c1 > 0.0f) || (c2 > 0.0f) || (c3 > 0.0f);
    return !(has_neg && has_pos);
}

static void tessellate_polygon_fill(tkmt_scene_t *s,
                                    const float *coords, uint32_t coord_count,
                                    uint32_t color, uint32_t cmd_flags) {
    uint32_t n = coord_count / 2u;
    if (n < 3 || tkmt_rgba_a(color) == 0) return;

    uint32_t v_start = s->dl_vert_count;

    if (n == 3) {
        emit_tri(s, coords[0], coords[1], coords[2], coords[3], coords[4], coords[5], color);
        dl_push_cmd(s, TKMT_CMD_TRIANGLES, v_start, 3, 0, cmd_flags);
        return;
    }

    /* Compute signed area to determine winding */
    double area = 0.0;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t j = (i + 1u) % n;
        area += (double)coords[2 * i] * (double)coords[2 * j + 1]
              - (double)coords[2 * j] * (double)coords[2 * i + 1];
    }
    int ccw = (area >= 0.0) ? 1 : -1;

    uint32_t *idx = (uint32_t *)malloc((size_t)n * sizeof(uint32_t));
    if (!idx) return;
    for (uint32_t i = 0; i < n; i++) {
        idx[i] = (ccw > 0) ? i : (n - 1u - i);
    }

    uint32_t rem = n;
    uint32_t guard = n * n + 16u;
    uint32_t i = 0;

    while (rem > 2 && guard-- > 0) {
        uint32_t i_prev = (i + rem - 1u) % rem;
        uint32_t i_curr = i % rem;
        uint32_t i_next = (i + 1u) % rem;

        uint32_t a = idx[i_prev];
        uint32_t b = idx[i_curr];
        uint32_t c = idx[i_next];

        float ax = coords[2 * a], ay = coords[2 * a + 1];
        float bx = coords[2 * b], by = coords[2 * b + 1];
        float cx = coords[2 * c], cy = coords[2 * c + 1];

        if (tri_cross2(ax, ay, bx, by, cx, cy) > 1e-6f) {
            int ear = 1;
            for (uint32_t k = 0; k < rem; k++) {
                uint32_t p = idx[k];
                if (p == a || p == b || p == c) continue;
                float px = coords[2 * p], py = coords[2 * p + 1];
                if (point_in_tri(px, py, ax, ay, bx, by, cx, cy)) {
                    ear = 0;
                    break;
                }
            }
            if (ear) {
                emit_tri(s, ax, ay, bx, by, cx, cy, color);
                memmove(&idx[i_curr], &idx[i_curr + 1u],
                        (size_t)(rem - i_curr - 1u) * sizeof(uint32_t));
                rem--;
                i = i_prev % rem;
                continue;
            }
        }
        i = (i + 1u) % rem;
    }

    /* Fallback fan if degenerate self-intersecting polygon stalled */
    if (rem > 2 && s->dl_vert_count == v_start) {
        for (uint32_t k = 1; k + 1u < rem; k++) {
            uint32_t a = idx[0], b = idx[k], c = idx[k + 1u];
            emit_tri(s,
                     coords[2 * a], coords[2 * a + 1],
                     coords[2 * b], coords[2 * b + 1],
                     coords[2 * c], coords[2 * c + 1],
                     color);
        }
    }

    free(idx);

    uint32_t v_added = s->dl_vert_count - v_start;
    if (v_added > 0) {
        dl_push_cmd(s, TKMT_CMD_TRIANGLES, v_start, v_added, 0, cmd_flags);
    }
}

/* -------------------------------------------------------------------------
 * Anchor offset helper
 * ------------------------------------------------------------------------- */

static void tess_anchor_offset(tkmt_anchor_t anchor, float w, float h,
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

/* -------------------------------------------------------------------------
 * Main Scene Tessellation & Render Entry Points
 * ------------------------------------------------------------------------- */

const tkmt_draw_list_t *tkmt_scene_tessellate(tkmt_scene_t *s,
                                              const tkmt_gfx_backend_t *backend,
                                              tkmt_gfx_surface_t *surf) {
    if (!s) return NULL;

    float dpi_scale = 1.0f;
#ifdef __APPLE__
    if (backend && surf && backend->id == TKMT_GFX_BACKEND_METAL) {
        dpi_scale = tkmt_metal_surface_scale(surf);
        if (dpi_scale < 1.0f) dpi_scale = 1.0f;
        if (dpi_scale > 4.0f) dpi_scale = 4.0f;
    }
#endif
    if (s->atlas && fabsf(tkmt_atlas_get_scale(s->atlas) - dpi_scale) > 0.01f) {
        tkmt_atlas_set_scale(s->atlas, dpi_scale);
        s->dirty_flags |= TKMT_DIRTY_GEOMETRY;
    }

    /* Fast path: pan/zoom (view_matrix) only; zero re-tessellation */
    if (s->draw_list_valid && !(s->dirty_flags & TKMT_DIRTY_GEOMETRY)) {
        s->draw_list.clear_color = s->clear_color;
        s->draw_list.do_clear    = s->do_clear;
        memcpy(s->draw_list.view_matrix, s->view_matrix, sizeof(float) * 9);
        if (s->dirty_flags & TKMT_DIRTY_VIEW) {
            s->view_only_updates++;
            s->dirty_flags &= ~TKMT_DIRTY_VIEW;
        }
        return &s->draw_list;
    }

    s->dl_vert_count = 0;
    s->dl_inst_count = 0;
    s->dl_cmd_count  = 0;

    int has_text = 0;
    tkmt_tex_id_t atlas_tex = 0;

    for (int32_t slot = s->z_head; slot != -1; slot = s->items[slot].z_next) {
        const tkmt_scene_item_t *it = &s->items[slot];
        if (it->id == 0 || it->state == TKMT_STATE_HIDDEN) continue;

        uint32_t cmd_flags = (it->flags & TKMT_ITEM_FLAG_AA) ? TKMT_CMD_FLAG_AA : 0u;
        uint32_t sdf_flags = (it->flags & TKMT_ITEM_FLAG_AA) ? TKMT_SDF_FLAG_AA : 0u;

        switch (it->type) {
            case TKMT_ITEM_RECTANGLE:
            case TKMT_ITEM_OVAL:
            case TKMT_ITEM_ARC: {
                if (it->coord_count < 4) break;
                float x0 = minf(it->coords[0], it->coords[2]);
                float y0 = minf(it->coords[1], it->coords[3]);
                float x1 = maxf(it->coords[0], it->coords[2]);
                float y1 = maxf(it->coords[1], it->coords[3]);
                if (!dl_reserve_insts(s, 1)) break;

                uint32_t first = s->dl_inst_count;
                tkmt_instance_t *inst = &s->dl_insts[s->dl_inst_count++];
                memset(inst, 0, sizeof(*inst));
                inst->x            = x0;
                inst->y            = y0;
                inst->w            = x1 - x0;
                inst->h            = y1 - y0;
                inst->fill_color   = it->fill_color;
                inst->stroke_color = it->outline_color;
                inst->stroke_width = it->width;
                inst->flags        = sdf_flags;

                if (it->type == TKMT_ITEM_RECTANGLE) {
                    if (it->corner_radius > 0.0f) {
                        inst->shape  = TKMT_SDF_ROUNDED_RECT;
                        inst->param0 = it->corner_radius;
                    } else {
                        inst->shape = TKMT_SDF_RECT;
                    }
                } else if (it->type == TKMT_ITEM_OVAL) {
                    inst->shape = TKMT_SDF_OVAL;
                } else {
                    inst->shape  = TKMT_SDF_ARC;
                    inst->param0 = it->start_deg * (float)(M_PI / 180.0);
                    inst->param1 = it->extent_deg * (float)(M_PI / 180.0);
                    if (it->arc_style == TKMT_ARC_CHORD) {
                        inst->flags |= TKMT_SDF_FLAG_ARC_CHORD;
                    } else if (it->arc_style == TKMT_ARC_ARC) {
                        inst->flags |= TKMT_SDF_FLAG_ARC_OUTLINE;
                    } else {
                        inst->flags |= TKMT_SDF_FLAG_ARC_PIE;
                    }
                }
                dl_push_cmd(s, TKMT_CMD_INSTANCES, first, 1, 0, cmd_flags);
                break;
            }

            case TKMT_ITEM_INSTANCE_BATCH: {
                if (it->inst_count == 0 || !it->instances) break;
                if (!dl_reserve_insts(s, it->inst_count)) break;
                uint32_t first = s->dl_inst_count;
                memcpy(s->dl_insts + first, it->instances,
                       (size_t)it->inst_count * sizeof(tkmt_instance_t));
                s->dl_inst_count += it->inst_count;
                dl_push_cmd(s, TKMT_CMD_INSTANCES, first, it->inst_count, 0, cmd_flags);
                break;
            }

            case TKMT_ITEM_LINE: {
                if (it->coord_count < 4) break;
                tessellate_polyline_dashed(s, it->coords, it->coord_count / 2u,
                                           (it->flags & TKMT_ITEM_FLAG_CLOSED) ? 1 : 0,
                                           it->width > 0.0f ? it->width : 1.0f,
                                           it->fill_color,
                                           it->cap_style, it->join_style,
                                           it->dash, it->dash_count, it->dash_offset,
                                           cmd_flags);
                break;
            }

            case TKMT_ITEM_POLYGON: {
                if (it->coord_count < 6) break;
                if (tkmt_rgba_a(it->fill_color) > 0) {
                    tessellate_polygon_fill(s, it->coords, it->coord_count,
                                            it->fill_color, cmd_flags);
                }
                if (tkmt_rgba_a(it->outline_color) > 0 && it->width > 0.0f) {
                    tessellate_polyline_dashed(s, it->coords, it->coord_count / 2u, 1,
                                               it->width, it->outline_color,
                                               it->cap_style, it->join_style,
                                               it->dash, it->dash_count, it->dash_offset,
                                               cmd_flags);
                }
                break;
            }

            case TKMT_ITEM_TEXT: {
                if (it->coord_count < 2 || !it->text || it->text[0] == '\0' || !s->atlas) break;
                if (tkmt_rgba_a(it->fill_color) == 0) break;

                float fsz = it->font_size > 0.0f ? it->font_size : 12.0f;
                float tw = 0.0f, th = 0.0f;
                uint32_t qcount = tkmt_atlas_layout_text(s->atlas, it->text, it->font_family,
                                                         fsz, NULL, 0, &tw, &th);
                if (qcount == 0) break;

                tkmt_glyph_quad_t *quads = (tkmt_glyph_quad_t *)malloc(
                    (size_t)qcount * sizeof(tkmt_glyph_quad_t));
                if (!quads) break;
                tkmt_atlas_layout_text(s->atlas, it->text, it->font_family,
                                       fsz, quads, qcount, &tw, &th);

                has_text = 1;
                if (backend && surf) {
                    atlas_tex = tkmt_atlas_sync_texture(s->atlas, backend, surf);
                }

                float ox = 0.0f, oy = 0.0f;
                tess_anchor_offset(it->anchor, tw, th, &ox, &oy);
                float bx = floorf((it->coords[0] + ox) * dpi_scale + 0.5f) / dpi_scale;
                float by = floorf((it->coords[1] + oy) * dpi_scale + 0.5f) / dpi_scale;

                uint32_t v_start = s->dl_vert_count;
                for (uint32_t q = 0; q < qcount; q++) {
                    emit_tex_quad(s,
                                  bx + quads[q].x0, by + quads[q].y0,
                                  bx + quads[q].x1, by + quads[q].y1,
                                  quads[q].u0, quads[q].v0,
                                  quads[q].u1, quads[q].v1,
                                  it->fill_color);
                }
                free(quads);

                uint32_t v_added = s->dl_vert_count - v_start;
                if (v_added > 0) {
                    dl_push_cmd(s, TKMT_CMD_GLYPHS, v_start, v_added, atlas_tex, cmd_flags);
                }
                break;
            }

            case TKMT_ITEM_IMAGE: {
                if (it->coord_count < 2 || it->tex_id == 0 || it->img_w == 0 || it->img_h == 0) {
                    break;
                }
                float w = (float)it->img_w;
                float h = (float)it->img_h;
                float ox = 0.0f, oy = 0.0f;
                tess_anchor_offset(it->anchor, w, h, &ox, &oy);
                float x0 = it->coords[0] + ox;
                float y0 = it->coords[1] + oy;

                uint32_t v_start = s->dl_vert_count;
                emit_tex_quad(s, x0, y0, x0 + w, y0 + h,
                              0.0f, 0.0f, 1.0f, 1.0f,
                              tkmt_rgba(255, 255, 255, 255));
                dl_push_cmd(s, TKMT_CMD_TEXTURED_TRIANGLES, v_start, 6, it->tex_id, cmd_flags);
                break;
            }

            case TKMT_ITEM_WINDOW:
            case TKMT_ITEM_NONE:
            default:
                break;
        }
    }

    /* If text was rasterized and backend/surf were provided, ensure final atlas upload */
    if (has_text && backend && surf && s->atlas) {
        tkmt_tex_id_t synced = tkmt_atlas_sync_texture(s->atlas, backend, surf);
        if (synced != 0) {
            for (uint32_t i = 0; i < s->dl_cmd_count; i++) {
                if (s->dl_cmds[i].type == TKMT_CMD_GLYPHS) {
                    s->dl_cmds[i].tex_id = synced;
                }
            }
        }
    }

    s->draw_list.clear_color    = s->clear_color;
    s->draw_list.do_clear       = s->do_clear;
    memcpy(s->draw_list.view_matrix, s->view_matrix, sizeof(float) * 9);
    s->draw_list.vertices       = s->dl_verts;
    s->draw_list.vertex_count   = s->dl_vert_count;
    s->draw_list.instances      = s->dl_insts;
    s->draw_list.instance_count = s->dl_inst_count;
    s->draw_list.cmds           = s->dl_cmds;
    s->draw_list.cmd_count      = s->dl_cmd_count;

    s->draw_list_valid = 1;
    s->tessellate_count++;
    s->dirty_flags &= ~(TKMT_DIRTY_GEOMETRY | TKMT_DIRTY_VIEW);

    return &s->draw_list;
}

int tkmt_scene_render(tkmt_scene_t *s,
                      const tkmt_gfx_backend_t *backend,
                      tkmt_gfx_surface_t *surf) {
    if (!s || !backend || !surf) return -1;
    const tkmt_draw_list_t *dl = tkmt_scene_tessellate(s, backend, surf);
    if (!dl) return -1;
    return backend->render(surf, dl);
}
