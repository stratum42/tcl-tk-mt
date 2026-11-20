/*
 * Tcl::Tk::MT - Pure C11 Deterministic Software CPU Reference Rasterizer
 *
 * Implements tkmt_gfx_backend_t with RGBA8888 offscreen framebuffer, exact
 * readback, and identical SDF/triangle/texture/glyph math to the Metal and
 * Vulkan shaders.
 */

#include "tkmt_gfx.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#  define M_PI 3.14159265358979323846
#endif

#define TKMT_TWO_PI 6.28318530717958647692f

typedef struct sw_texture {
    int               in_use;
    uint32_t          width;
    uint32_t          height;
    tkmt_tex_format_t fmt;
    uint8_t          *data;
} sw_texture_t;

struct tkmt_gfx_surface {
    uint32_t      width;
    uint32_t      height;
    float         scale;
    int           headless;
    uint8_t      *rgba;      /* width * height * 4 */
    sw_texture_t *textures;
    uint32_t      tex_cap;
};

/* -------------------------------------------------------------------------
 * Math & Blending Helpers
 * ------------------------------------------------------------------------- */

static inline float clamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

static inline uint8_t f2u8(float v) {
    float c = clamp01(v) * 255.0f + 0.5f;
    if (c < 0.0f) return 0;
    if (c > 255.0f) return 255;
    return (uint8_t)c;
}

static inline void blend_pixel(uint8_t *dst, float sr, float sg, float sb, float sa) {
    if (sa <= 0.0f) return;
    if (sa >= 1.0f) {
        dst[0] = f2u8(sr);
        dst[1] = f2u8(sg);
        dst[2] = f2u8(sb);
        dst[3] = 255u;
        return;
    }
    float inv_sa = 1.0f - sa;
    float dr = dst[0] * (1.0f / 255.0f);
    float dg = dst[1] * (1.0f / 255.0f);
    float db = dst[2] * (1.0f / 255.0f);
    float da = dst[3] * (1.0f / 255.0f);

    float out_r = sr * sa + dr * inv_sa;
    float out_g = sg * sa + dg * inv_sa;
    float out_b = sb * sa + db * inv_sa;
    float out_a = sa + da * inv_sa;

    dst[0] = f2u8(out_r);
    dst[1] = f2u8(out_g);
    dst[2] = f2u8(out_b);
    dst[3] = f2u8(out_a);
}

static inline void unpack_rgba(uint32_t c, float *r, float *g, float *b, float *a) {
    *r = (float)(c & 0xFFu) * (1.0f / 255.0f);
    *g = (float)((c >> 8) & 0xFFu) * (1.0f / 255.0f);
    *b = (float)((c >> 16) & 0xFFu) * (1.0f / 255.0f);
    *a = (float)((c >> 24) & 0xFFu) * (1.0f / 255.0f);
}

static inline void compute_clip_bounds(const tkmt_gfx_surface_t *surf,
                                       const tkmt_clip_rect_t *clip,
                                       int32_t *x0, int32_t *y0,
                                       int32_t *x1, int32_t *y1) {
    int32_t cx0 = 0, cy0 = 0;
    int32_t cx1 = (int32_t)surf->width;
    int32_t cy1 = (int32_t)surf->height;
    if (clip && clip->w > 0 && clip->h > 0) {
        if (clip->x > cx0) cx0 = clip->x;
        if (clip->y > cy0) cy0 = clip->y;
        if (clip->x + clip->w < cx1) cx1 = clip->x + clip->w;
        if (clip->y + clip->h < cy1) cy1 = clip->y + clip->h;
    }
    *x0 = cx0; *y0 = cy0; *x1 = cx1; *y1 = cy1;
}

static const sw_texture_t *get_tex(const tkmt_gfx_surface_t *surf, tkmt_tex_id_t id) {
    if (!surf || id == 0 || id > surf->tex_cap) return NULL;
    const sw_texture_t *t = &surf->textures[id - 1];
    return t->in_use ? t : NULL;
}

/* Clamped bilinear sample matching GPU linear + clamp_to_edge */
static void sample_rgba8(const sw_texture_t *t, float u, float v,
                         float *r, float *g, float *b, float *a) {
    if (!t || !t->data || t->width == 0 || t->height == 0) {
        *r = *g = *b = *a = 1.0f;
        return;
    }
    float fx = u * (float)t->width  - 0.5f;
    float fy = v * (float)t->height - 0.5f;
    int32_t ix0 = (int32_t)floorf(fx);
    int32_t iy0 = (int32_t)floorf(fy);
    float tx = fx - (float)ix0;
    float ty = fy - (float)iy0;
    int32_t ix1 = ix0 + 1;
    int32_t iy1 = iy0 + 1;

    int32_t maxx = (int32_t)t->width - 1;
    int32_t maxy = (int32_t)t->height - 1;
    if (ix0 < 0) ix0 = 0; else if (ix0 > maxx) ix0 = maxx;
    if (ix1 < 0) ix1 = 0; else if (ix1 > maxx) ix1 = maxx;
    if (iy0 < 0) iy0 = 0; else if (iy0 > maxy) iy0 = maxy;
    if (iy1 < 0) iy1 = 0; else if (iy1 > maxy) iy1 = maxy;

    const uint8_t *p00 = t->data + ((size_t)iy0 * t->width + (size_t)ix0) * 4;
    const uint8_t *p10 = t->data + ((size_t)iy0 * t->width + (size_t)ix1) * 4;
    const uint8_t *p01 = t->data + ((size_t)iy1 * t->width + (size_t)ix0) * 4;
    const uint8_t *p11 = t->data + ((size_t)iy1 * t->width + (size_t)ix1) * 4;

    float w00 = (1.0f - tx) * (1.0f - ty);
    float w10 = tx * (1.0f - ty);
    float w01 = (1.0f - tx) * ty;
    float w11 = tx * ty;

    float inv = 1.0f / 255.0f;
    *r = (p00[0]*w00 + p10[0]*w10 + p01[0]*w01 + p11[0]*w11) * inv;
    *g = (p00[1]*w00 + p10[1]*w10 + p01[1]*w01 + p11[1]*w11) * inv;
    *b = (p00[2]*w00 + p10[2]*w10 + p01[2]*w01 + p11[2]*w11) * inv;
    *a = (p00[3]*w00 + p10[3]*w10 + p01[3]*w01 + p11[3]*w11) * inv;
}

static float sample_r8(const sw_texture_t *t, float u, float v) {
    if (!t || !t->data || t->width == 0 || t->height == 0) return 0.0f;
    float fx = u * (float)t->width  - 0.5f;
    float fy = v * (float)t->height - 0.5f;
    int32_t ix0 = (int32_t)floorf(fx);
    int32_t iy0 = (int32_t)floorf(fy);
    float tx = fx - (float)ix0;
    float ty = fy - (float)iy0;
    int32_t ix1 = ix0 + 1;
    int32_t iy1 = iy0 + 1;

    int32_t maxx = (int32_t)t->width - 1;
    int32_t maxy = (int32_t)t->height - 1;
    if (ix0 < 0) ix0 = 0; else if (ix0 > maxx) ix0 = maxx;
    if (ix1 < 0) ix1 = 0; else if (ix1 > maxx) ix1 = maxx;
    if (iy0 < 0) iy0 = 0; else if (iy0 > maxy) iy0 = maxy;
    if (iy1 < 0) iy1 = 0; else if (iy1 > maxy) iy1 = maxy;

    float v00 = (float)t->data[(size_t)iy0 * t->width + (size_t)ix0];
    float v10 = (float)t->data[(size_t)iy0 * t->width + (size_t)ix1];
    float v01 = (float)t->data[(size_t)iy1 * t->width + (size_t)ix0];
    float v11 = (float)t->data[(size_t)iy1 * t->width + (size_t)ix1];

    float w00 = (1.0f - tx) * (1.0f - ty);
    float w10 = tx * (1.0f - ty);
    float w01 = (1.0f - tx) * ty;
    float w11 = tx * ty;
    return (v00*w00 + v10*w10 + v01*w01 + v11*w11) * (1.0f / 255.0f);
}

/* -------------------------------------------------------------------------
 * Triangle Rasterization (Solid, Textured RGBA8, Glyph R8)
 * ------------------------------------------------------------------------- */

static inline float edge_fn(float ax, float ay, float bx, float by, float px, float py) {
    return (px - ax) * (by - ay) - (py - ay) * (bx - ax);
}

static inline int is_top_left(float ax, float ay, float bx, float by) {
    return (ay == by && bx < ax) || (by > ay);
}

static void raster_triangle(tkmt_gfx_surface_t *surf,
                            const tkmt_vertex_t *v0,
                            const tkmt_vertex_t *v1,
                            const tkmt_vertex_t *v2,
                            const float m[9],
                            tkmt_draw_cmd_type_t mode,
                            const sw_texture_t *tex,
                            int32_t cx0, int32_t cy0, int32_t cx1, int32_t cy1) {
    float x0 = m[0]*v0->x + m[1]*v0->y + m[2];
    float y0 = m[3]*v0->x + m[4]*v0->y + m[5];
    float x1 = m[0]*v1->x + m[1]*v1->y + m[2];
    float y1 = m[3]*v1->x + m[4]*v1->y + m[5];
    float x2 = m[0]*v2->x + m[1]*v2->y + m[2];
    float y2 = m[3]*v2->x + m[4]*v2->y + m[5];

    float area = edge_fn(x0, y0, x1, y1, x2, y2);
    if (fabsf(area) < 1e-6f) return;

    const tkmt_vertex_t *a = v0, *b = v1, *c = v2;
    if (area < 0.0f) {
        float tx = x1; x1 = x2; x2 = tx;
        float ty = y1; y1 = y2; y2 = ty;
        const tkmt_vertex_t *tv = b; b = c; c = tv;
        area = -area;
    }

    float minx = fminf(x0, fminf(x1, x2));
    float maxx = fmaxf(x0, fmaxf(x1, x2));
    float miny = fminf(y0, fminf(y1, y2));
    float maxy = fmaxf(y0, fmaxf(y1, y2));

    int32_t ix0 = (int32_t)floorf(minx);
    int32_t iy0 = (int32_t)floorf(miny);
    int32_t ix1 = (int32_t)ceilf(maxx);
    int32_t iy1 = (int32_t)ceilf(maxy);

    if (ix0 < cx0) ix0 = cx0;
    if (iy0 < cy0) iy0 = cy0;
    if (ix1 > cx1) ix1 = cx1;
    if (iy1 > cy1) iy1 = cy1;
    if (ix0 >= ix1 || iy0 >= iy1) return;

    float r0, g0, b0, a0; unpack_rgba(a->color, &r0, &g0, &b0, &a0);
    float r1, g1, b1, a1; unpack_rgba(b->color, &r1, &g1, &b1, &a1);
    float r2, g2, b2, a2; unpack_rgba(c->color, &r2, &g2, &b2, &a2);

    float inv_area = 1.0f / area;
    int tl0 = is_top_left(x1, y1, x2, y2);
    int tl1 = is_top_left(x2, y2, x0, y0);
    int tl2 = is_top_left(x0, y0, x1, y1);

    for (int32_t py = iy0; py < iy1; py++) {
        float sy = (float)py + 0.5f;
        uint8_t *row = surf->rgba + (size_t)py * surf->width * 4;
        for (int32_t px = ix0; px < ix1; px++) {
            float sx = (float)px + 0.5f;
            float e0 = edge_fn(x1, y1, x2, y2, sx, sy);
            float e1 = edge_fn(x2, y2, x0, y0, sx, sy);
            float e2 = edge_fn(x0, y0, x1, y1, sx, sy);

            if ((e0 > 0.0f || (e0 == 0.0f && tl0)) &&
                (e1 > 0.0f || (e1 == 0.0f && tl1)) &&
                (e2 > 0.0f || (e2 == 0.0f && tl2))) {
                float w0 = e0 * inv_area;
                float w1 = e1 * inv_area;
                float w2 = e2 * inv_area;

                float cr = r0*w0 + r1*w1 + r2*w2;
                float cg = g0*w0 + g1*w1 + g2*w2;
                float cb = b0*w0 + b1*w1 + b2*w2;
                float ca = a0*w0 + a1*w1 + a2*w2;

                if (mode == TKMT_CMD_TEXTURED_TRIANGLES && tex) {
                    float u = a->u*w0 + b->u*w1 + c->u*w2;
                    float v = a->v*w0 + b->v*w1 + c->v*w2;
                    float tr, tg, tb, ta;
                    sample_rgba8(tex, u, v, &tr, &tg, &tb, &ta);
                    cr *= tr; cg *= tg; cb *= tb; ca *= ta;
                } else if (mode == TKMT_CMD_GLYPHS && tex) {
                    float u = a->u*w0 + b->u*w1 + c->u*w2;
                    float v = a->v*w0 + b->v*w1 + c->v*w2;
                    float cov = sample_r8(tex, u, v);
                    if (cov > 0.0f && cov < 1.0f) {
                        float luma  = cr * 0.299f + cg * 0.587f + cb * 0.114f;
                        float t     = clamp01((luma - 0.25f) / 0.75f);
                        float gamma = 1.0f + (0.62f - 1.0f) * t;
                        cov = powf(cov, gamma);
                    }
                    ca *= cov;
                }

                blend_pixel(row + (size_t)px * 4, cr, cg, cb, ca);
            }
        }
    }
}

/* -------------------------------------------------------------------------
 * Instanced 2D SDF Shape Rasterizer
 * ------------------------------------------------------------------------- */

static float eval_sdf(const tkmt_instance_t *inst, float lx, float ly,
                      float *out_arc_mask) {
    float hx = inst->w * 0.5f;
    float hy = inst->h * 0.5f;
    float px = lx - hx;
    float py = ly - hy;
    *out_arc_mask = 1.0f;

    switch ((tkmt_sdf_shape_t)inst->shape) {
        case TKMT_SDF_RECT: {
            float dx = fabsf(px) - hx;
            float dy = fabsf(py) - hy;
            float ox = fmaxf(dx, 0.0f);
            float oy = fmaxf(dy, 0.0f);
            return sqrtf(ox*ox + oy*oy) + fminf(fmaxf(dx, dy), 0.0f);
        }
        case TKMT_SDF_ROUNDED_RECT: {
            float r = inst->param0;
            float maxr = fminf(hx, hy);
            if (r < 0.0f) r = 0.0f;
            if (r > maxr) r = maxr;
            float qx = fabsf(px) - (hx - r);
            float qy = fabsf(py) - (hy - r);
            float ox = fmaxf(qx, 0.0f);
            float oy = fmaxf(qy, 0.0f);
            return sqrtf(ox*ox + oy*oy) + fminf(fmaxf(qx, qy), 0.0f) - r;
        }
        case TKMT_SDF_OVAL:
        case TKMT_SDF_ARC: {
            float rx = fmaxf(hx, 1e-4f);
            float ry = fmaxf(hy, 1e-4f);
            float nx = px / rx;
            float ny = py / ry;
            float k0 = sqrtf(nx*nx + ny*ny);
            float gx = px / (rx * rx);
            float gy = py / (ry * ry);
            float k1 = sqrtf(gx*gx + gy*gy);
            float d = (k1 > 1e-6f) ? (k0 * (k0 - 1.0f) / k1) : -fminf(rx, ry);

            if (inst->shape == TKMT_SDF_ARC) {
                float start = inst->param0;
                float ext   = inst->param1;
                if (ext < 0.0f) {
                    start += ext;
                    ext = -ext;
                }
                if (ext < TKMT_TWO_PI - 1e-4f) {
                    float ang = atan2f(-py, px); /* Tk: 0=+X, +CCW */
                    float rel = fmodf(ang - start, TKMT_TWO_PI);
                    if (rel < 0.0f) rel += TKMT_TWO_PI;
                    if (rel > ext) {
                        *out_arc_mask = 0.0f;
                    }
                }
            }
            return d;
        }
        case TKMT_SDF_QUAD_TEX:
        default: {
            float dx = fabsf(px) - hx;
            float dy = fabsf(py) - hy;
            float ox = fmaxf(dx, 0.0f);
            float oy = fmaxf(dy, 0.0f);
            return sqrtf(ox*ox + oy*oy) + fminf(fmaxf(dx, dy), 0.0f);
        }
    }
}

static void raster_instance(tkmt_gfx_surface_t *surf,
                            const tkmt_instance_t *inst,
                            const float m[9],
                            const sw_texture_t *tex,
                            int32_t cx0, int32_t cy0, int32_t cx1, int32_t cy1) {
    if (inst->w <= 0.0f || inst->h <= 0.0f) return;

    float det = m[0]*m[4] - m[1]*m[3];
    if (fabsf(det) < 1e-8f) return;
    float inv_det = 1.0f / det;
    float im0 =  m[4] * inv_det;
    float im1 = -m[1] * inv_det;
    float im3 = -m[3] * inv_det;
    float im4 =  m[0] * inv_det;

    float sx_len = sqrtf(m[0]*m[0] + m[3]*m[3]);
    float sy_len = sqrtf(m[1]*m[1] + m[4]*m[4]);
    float px_scale = 0.5f * (sx_len + sy_len);
    if (px_scale < 1e-4f) px_scale = 1.0f;

    float pad = (inst->stroke_width > 0.0f ? inst->stroke_width * 0.5f : 0.0f) + 2.0f / px_scale;
    float x0 = inst->x - pad, y0 = inst->y - pad;
    float x1 = inst->x + inst->w + pad, y1 = inst->y + inst->h + pad;

    float corners_x[4] = {
        m[0]*x0 + m[1]*y0 + m[2],
        m[0]*x1 + m[1]*y0 + m[2],
        m[0]*x1 + m[1]*y1 + m[2],
        m[0]*x0 + m[1]*y1 + m[2]
    };
    float corners_y[4] = {
        m[3]*x0 + m[4]*y0 + m[5],
        m[3]*x1 + m[4]*y0 + m[5],
        m[3]*x1 + m[4]*y1 + m[5],
        m[3]*x0 + m[4]*y1 + m[5]
    };

    float minx = corners_x[0], maxx = corners_x[0];
    float miny = corners_y[0], maxy = corners_y[0];
    for (int i = 1; i < 4; i++) {
        if (corners_x[i] < minx) minx = corners_x[i];
        if (corners_x[i] > maxx) maxx = corners_x[i];
        if (corners_y[i] < miny) miny = corners_y[i];
        if (corners_y[i] > maxy) maxy = corners_y[i];
    }

    int32_t ix0 = (int32_t)floorf(minx);
    int32_t iy0 = (int32_t)floorf(miny);
    int32_t ix1 = (int32_t)ceilf(maxx);
    int32_t iy1 = (int32_t)ceilf(maxy);

    if (ix0 < cx0) ix0 = cx0;
    if (iy0 < cy0) iy0 = cy0;
    if (ix1 > cx1) ix1 = cx1;
    if (iy1 > cy1) iy1 = cy1;
    if (ix0 >= ix1 || iy0 >= iy1) return;

    float fr, fg, fb, fa; unpack_rgba(inst->fill_color, &fr, &fg, &fb, &fa);
    float sr, sg, sb, sa; unpack_rgba(inst->stroke_color, &sr, &sg, &sb, &sa);
    int use_aa     = (inst->flags & TKMT_SDF_FLAG_AA) ? 1 : 0;
    int has_stroke = (inst->stroke_width > 0.0f && sa > 0.0f);
    float half_sw  = inst->stroke_width * 0.5f * px_scale;
    int is_arc_outline = (inst->shape == TKMT_SDF_ARC &&
                          ((inst->flags & TKMT_SDF_FLAG_ARC_MASK) == TKMT_SDF_FLAG_ARC_OUTLINE));

    for (int32_t py = iy0; py < iy1; py++) {
        float sy = (float)py + 0.5f - m[5];
        uint8_t *row = surf->rgba + (size_t)py * surf->width * 4;
        for (int32_t px = ix0; px < ix1; px++) {
            float sx = (float)px + 0.5f - m[2];
            float wx = im0*sx + im1*sy;
            float wy = im3*sx + im4*sy;
            float lx = wx - inst->x;
            float ly = wy - inst->y;

            if (inst->shape == TKMT_SDF_QUAD_TEX && tex) {
                if (lx >= 0.0f && lx <= inst->w && ly >= 0.0f && ly <= inst->h) {
                    float u = lx / inst->w;
                    float v = ly / inst->h;
                    float tr, tg, tb, ta;
                    sample_rgba8(tex, u, v, &tr, &tg, &tb, &ta);
                    float mr = (inst->fill_color != 0) ? fr : 1.0f;
                    float mg = (inst->fill_color != 0) ? fg : 1.0f;
                    float mb = (inst->fill_color != 0) ? fb : 1.0f;
                    float ma = (inst->fill_color != 0) ? fa : 1.0f;
                    blend_pixel(row + (size_t)px * 4, tr*mr, tg*mg, tb*mb, ta*ma);
                }
                continue;
            }

            float arc_mask = 1.0f;
            float d_px = eval_sdf(inst, lx, ly, &arc_mask) * px_scale;
            if (arc_mask <= 0.0f) continue;

            if (fa > 0.0f && !is_arc_outline) {
                float fill_cov = use_aa ? clamp01(0.5f - d_px) : (d_px <= 0.0f ? 1.0f : 0.0f);
                if (fill_cov > 0.0f) {
                    blend_pixel(row + (size_t)px * 4, fr, fg, fb, fa * fill_cov);
                }
            }

            if (has_stroke) {
                float sd = fabsf(d_px) - half_sw;
                float stroke_cov = use_aa ? clamp01(0.5f - sd) : (sd <= 0.0f ? 1.0f : 0.0f);
                if (stroke_cov > 0.0f) {
                    blend_pixel(row + (size_t)px * 4, sr, sg, sb, sa * stroke_cov);
                }
            }
        }
    }
}

/* -------------------------------------------------------------------------
 * Backend vtable implementation
 * ------------------------------------------------------------------------- */

static int sw_probe(void) { return 1; }
static int sw_init(void)  { return 0; }
static void sw_shutdown(void) {}

static tkmt_gfx_surface_t *sw_create_surface(const tkmt_surface_desc_t *desc) {
    if (!desc || desc->width == 0 || desc->height == 0) return NULL;
    tkmt_gfx_surface_t *surf = (tkmt_gfx_surface_t *)calloc(1, sizeof(*surf));
    if (!surf) return NULL;

    size_t bytes = (size_t)desc->width * (size_t)desc->height * 4u;
    surf->rgba = (uint8_t *)calloc(1, bytes);
    if (!surf->rgba) {
        free(surf);
        return NULL;
    }
    surf->width    = desc->width;
    surf->height   = desc->height;
    surf->scale    = (desc->scale > 0.0f) ? desc->scale : 1.0f;
    surf->headless = desc->headless;
    return surf;
}

static void sw_destroy_surface(tkmt_gfx_surface_t *surf) {
    if (!surf) return;
    if (surf->textures) {
        for (uint32_t i = 0; i < surf->tex_cap; i++) {
            free(surf->textures[i].data);
        }
        free(surf->textures);
    }
    free(surf->rgba);
    free(surf);
}

static int sw_resize_surface(tkmt_gfx_surface_t *surf,
                             uint32_t width, uint32_t height, float scale) {
    if (!surf || width == 0 || height == 0) return -1;
    if (surf->width == width && surf->height == height) {
        if (scale > 0.0f) surf->scale = scale;
        return 0;
    }
    size_t bytes = (size_t)width * (size_t)height * 4u;
    uint8_t *buf = (uint8_t *)calloc(1, bytes);
    if (!buf) return -1;
    free(surf->rgba);
    surf->rgba   = buf;
    surf->width  = width;
    surf->height = height;
    if (scale > 0.0f) surf->scale = scale;
    return 0;
}

static tkmt_tex_id_t sw_texture_create(tkmt_gfx_surface_t *surf,
                                       uint32_t width, uint32_t height,
                                       tkmt_tex_format_t fmt,
                                       const uint8_t *pixels) {
    if (!surf || width == 0 || height == 0) return 0;
    size_t bpp   = (fmt == TKMT_TEX_R8) ? 1u : 4u;
    size_t bytes = (size_t)width * (size_t)height * bpp;

    uint32_t slot = surf->tex_cap;
    for (uint32_t i = 0; i < surf->tex_cap; i++) {
        if (!surf->textures[i].in_use) {
            slot = i;
            break;
        }
    }
    if (slot == surf->tex_cap) {
        uint32_t new_cap = surf->tex_cap ? surf->tex_cap * 2u : 16u;
        sw_texture_t *arr = (sw_texture_t *)realloc(surf->textures, new_cap * sizeof(*arr));
        if (!arr) return 0;
        memset(arr + surf->tex_cap, 0, (new_cap - surf->tex_cap) * sizeof(*arr));
        surf->textures = arr;
        surf->tex_cap  = new_cap;
    }

    uint8_t *data = (uint8_t *)calloc(1, bytes);
    if (!data) return 0;
    if (pixels) memcpy(data, pixels, bytes);

    surf->textures[slot].in_use = 1;
    surf->textures[slot].width  = width;
    surf->textures[slot].height = height;
    surf->textures[slot].fmt    = fmt;
    surf->textures[slot].data   = data;
    return slot + 1u;
}

static int sw_texture_update(tkmt_gfx_surface_t *surf, tkmt_tex_id_t tex,
                             uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                             const uint8_t *pixels) {
    if (!surf || !pixels || tex == 0 || tex > surf->tex_cap) return -1;
    sw_texture_t *t = &surf->textures[tex - 1];
    if (!t->in_use || x + w > t->width || y + h > t->height) return -1;
    size_t bpp = (t->fmt == TKMT_TEX_R8) ? 1u : 4u;
    for (uint32_t row = 0; row < h; row++) {
        memcpy(t->data + ((size_t)(y + row) * t->width + x) * bpp,
               pixels + (size_t)row * w * bpp,
               (size_t)w * bpp);
    }
    return 0;
}

static void sw_texture_destroy(tkmt_gfx_surface_t *surf, tkmt_tex_id_t tex) {
    if (!surf || tex == 0 || tex > surf->tex_cap) return;
    sw_texture_t *t = &surf->textures[tex - 1];
    if (t->in_use) {
        free(t->data);
        memset(t, 0, sizeof(*t));
    }
}

static int sw_render(tkmt_gfx_surface_t *surf, const tkmt_draw_list_t *list) {
    if (!surf || !list) return -1;

    if (list->do_clear) {
        uint8_t cr = tkmt_rgba_r(list->clear_color);
        uint8_t cg = tkmt_rgba_g(list->clear_color);
        uint8_t cb = tkmt_rgba_b(list->clear_color);
        uint8_t ca = tkmt_rgba_a(list->clear_color);
        size_t total = (size_t)surf->width * (size_t)surf->height;
        uint8_t *p = surf->rgba;
        for (size_t i = 0; i < total; i++) {
            p[0] = cr; p[1] = cg; p[2] = cb; p[3] = ca;
            p += 4;
        }
    }

    uint64_t total_verts = 0;
    uint64_t total_insts = 0;

    for (uint32_t ci = 0; ci < list->cmd_count; ci++) {
        const tkmt_draw_cmd_t *cmd = &list->cmds[ci];
        int32_t cx0, cy0, cx1, cy1;
        compute_clip_bounds(surf, &cmd->clip, &cx0, &cy0, &cx1, &cy1);
        if (cx0 >= cx1 || cy0 >= cy1) continue;

        const sw_texture_t *tex = get_tex(surf, cmd->tex_id);

        if (cmd->type == TKMT_CMD_INSTANCES) {
            if (!list->instances || cmd->first >= list->instance_count) continue;
            uint32_t end = cmd->first + cmd->count;
            if (end > list->instance_count) end = list->instance_count;
            for (uint32_t i = cmd->first; i < end; i++) {
                raster_instance(surf, &list->instances[i], list->view_matrix,
                                tex, cx0, cy0, cx1, cy1);
            }
            total_insts += (end - cmd->first);
        } else {
            if (!list->vertices || cmd->first >= list->vertex_count) continue;
            uint32_t end = cmd->first + cmd->count;
            if (end > list->vertex_count) end = list->vertex_count;
            for (uint32_t i = cmd->first; i + 2 < end; i += 3) {
                raster_triangle(surf,
                                &list->vertices[i],
                                &list->vertices[i + 1],
                                &list->vertices[i + 2],
                                list->view_matrix,
                                cmd->type, tex, cx0, cy0, cx1, cy1);
            }
            total_verts += (end - cmd->first);
        }
    }

    tkmt_gfx_record_frame("software", list->cmd_count, total_verts, total_insts, 1);
    return 0;
}

static int sw_readback_rgba(tkmt_gfx_surface_t *surf, uint8_t *out_rgba, size_t buf_bytes) {
    if (!surf || !out_rgba) return -1;
    size_t needed = (size_t)surf->width * (size_t)surf->height * 4u;
    if (buf_bytes < needed) return -1;
    memcpy(out_rgba, surf->rgba, needed);
    tkmt_gfx_record_readback();
    return 0;
}

static const tkmt_gfx_backend_t g_software_backend = {
    .id              = TKMT_GFX_BACKEND_SOFTWARE,
    .name            = "software",
    .description     = "Deterministic C11 RGBA8888 CPU reference rasterizer",
    .device_class    = TKMT_GFX_DEV_CPU,
    .priority        = 10,
    .caps            = TKMT_GFX_CAP_OFFSCREEN
                     | TKMT_GFX_CAP_WINDOWED
                     | TKMT_GFX_CAP_INSTANCING
                     | TKMT_GFX_CAP_SDF
                     | TKMT_GFX_CAP_GLYPH_ATLAS
                     | TKMT_GFX_CAP_RGBA_TEXTURE
                     | TKMT_GFX_CAP_HIDPI,
    .probe           = sw_probe,
    .init            = sw_init,
    .shutdown        = sw_shutdown,
    .create_surface  = sw_create_surface,
    .destroy_surface = sw_destroy_surface,
    .resize_surface  = sw_resize_surface,
    .texture_create  = sw_texture_create,
    .texture_update  = sw_texture_update,
    .texture_destroy = sw_texture_destroy,
    .render          = sw_render,
    .readback_rgba   = sw_readback_rgba
};

const tkmt_gfx_backend_t *tkmt_gfx_get_software_backend(void) {
    return &g_software_backend;
}
