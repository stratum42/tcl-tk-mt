/*
 * Tcl::Tk::MT - Metal Shading Language (MSL) 2D Canvas Shaders
 *
 * Matches c/gfx/gfx_software.c math for two-tier parity:
 *   - Exact bit-for-bit match on integer non-AA fills & 1:1 RGBA8 blits
 *   - <= 2/255 max channel delta and >= 99.9% match on AA SDF & R8 glyph text
 */

#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4 view_row0; /* m[0], m[1], m[2], 0 */
    float4 view_row1; /* m[3], m[4], m[5], 0 */
    float2 viewport;  /* width, height */
    float  px_scale;  /* average pixel scale of view_matrix */
    float  _pad;
};

struct TkmtVertex {
    float2 pos;
    float2 uv;
    uint   color;
    uint   flags;
};

struct TkmtInstance {
    float4 rect;        /* x, y, w, h */
    uint   fill_color;
    uint   stroke_color;
    float  stroke_width;
    float  param0;
    float  param1;
    uint   shape;
    uint   flags;
    uint   _pad;
};

struct TriOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

struct InstOut {
    float4 position [[position]];
    float2 local_pos;
    float2 size;
    float4 fill_color;
    float4 stroke_color;
    float  stroke_width;
    float  param0;
    float  param1;
    uint   shape;
    uint   flags;
};

static inline float4 unpack_rgba8(uint c) {
    return float4(
        float(c & 0xFFu) / 255.0,
        float((c >> 8) & 0xFFu) / 255.0,
        float((c >> 16) & 0xFFu) / 255.0,
        float((c >> 24) & 0xFFu) / 255.0
    );
}

static inline float2 to_ndc(float2 px, float2 vp) {
    return float2((px.x / vp.x) * 2.0 - 1.0,
                  1.0 - (px.y / vp.y) * 2.0);
}

vertex TriOut vs_tri(uint vid [[vertex_id]],
                     const device TkmtVertex *verts [[buffer(0)]],
                     constant FrameUniforms &u [[buffer(1)]]) {
    TkmtVertex v = verts[vid];
    float2 sx = float2(
        u.view_row0.x * v.pos.x + u.view_row0.y * v.pos.y + u.view_row0.z,
        u.view_row1.x * v.pos.x + u.view_row1.y * v.pos.y + u.view_row1.z
    );
    TriOut out;
    out.position = float4(to_ndc(sx, u.viewport), 0.0, 1.0);
    out.uv       = v.uv;
    out.color    = unpack_rgba8(v.color);
    return out;
}

fragment float4 fs_solid(TriOut in [[stage_in]]) {
    return in.color;
}

fragment float4 fs_tex_rgba(TriOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler samp [[sampler(0)]]) {
    float4 t = tex.sample(samp, in.uv);
    return t * in.color;
}

fragment float4 fs_glyph_r8(TriOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler samp [[sampler(0)]]) {
    float cov = tex.sample(samp, in.uv).r;
    if (cov > 0.0 && cov < 1.0) {
        float luma  = dot(in.color.rgb, float3(0.299, 0.587, 0.114));
        float t     = clamp((luma - 0.25) / 0.75, 0.0, 1.0);
        float gamma = mix(1.0, 0.62, t);
        cov = pow(cov, gamma);
    }
    return float4(in.color.rgb, in.color.a * cov);
}

vertex InstOut vs_inst(uint vid [[vertex_id]],
                       uint iid [[instance_id]],
                       const device TkmtInstance *insts [[buffer(0)]],
                       constant FrameUniforms &u [[buffer(1)]]) {
    TkmtInstance inst = insts[iid];
    float pad = (inst.stroke_width > 0.0 ? inst.stroke_width * 0.5 : 0.0)
              + (2.0 / max(u.px_scale, 1e-4));

    const float2 quad[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0)
    };
    float2 q = quad[vid];
    float2 local = float2(
        mix(-pad, inst.rect.z + pad, q.x),
        mix(-pad, inst.rect.w + pad, q.y)
    );
    float2 world = inst.rect.xy + local;
    float2 sx = float2(
        u.view_row0.x * world.x + u.view_row0.y * world.y + u.view_row0.z,
        u.view_row1.x * world.x + u.view_row1.y * world.y + u.view_row1.z
    );

    InstOut out;
    out.position     = float4(to_ndc(sx, u.viewport), 0.0, 1.0);
    out.local_pos    = local;
    out.size         = inst.rect.zw;
    out.fill_color   = unpack_rgba8(inst.fill_color);
    out.stroke_color = unpack_rgba8(inst.stroke_color);
    out.stroke_width = inst.stroke_width;
    out.param0       = inst.param0;
    out.param1       = inst.param1;
    out.shape        = inst.shape;
    out.flags        = inst.flags;
    return out;
}

fragment float4 fs_inst(InstOut in [[stage_in]],
                        constant FrameUniforms &u [[buffer(1)]],
                        texture2d<float> tex [[texture(0)]],
                        sampler samp [[sampler(0)]]) {
    if (in.shape == 4u) {
        if (in.local_pos.x < 0.0 || in.local_pos.x > in.size.x ||
            in.local_pos.y < 0.0 || in.local_pos.y > in.size.y) {
            discard_fragment();
        }
        float2 uv = in.local_pos / max(in.size, float2(1e-4));
        float4 t  = tex.sample(samp, uv);
        float4 m  = (in.fill_color.a > 0.0 || in.fill_color.r > 0.0 ||
                     in.fill_color.g > 0.0 || in.fill_color.b > 0.0)
                  ? in.fill_color : float4(1.0);
        return t * m;
    }

    float2 half_sz = in.size * 0.5;
    float2 p       = in.local_pos - half_sz;
    float d        = 0.0;

    if (in.shape == 0u) {
        float2 q = abs(p) - half_sz;
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    } else if (in.shape == 1u) {
        float r = clamp(in.param0, 0.0, min(half_sz.x, half_sz.y));
        float2 q = abs(p) - (half_sz - r);
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    } else {
        float2 r = max(half_sz, float2(1e-4));
        float k0 = length(p / r);
        float k1 = length(p / (r * r));
        d = (k1 > 1e-6) ? (k0 * (k0 - 1.0) / k1) : -min(r.x, r.y);

        if (in.shape == 3u) {
            float start = in.param0;
            float ext   = in.param1;
            if (ext < 0.0) {
                start += ext;
                ext = -ext;
            }
            const float TWO_PI = 6.28318530717958647692;
            if (ext < TWO_PI - 1e-4) {
                float ang = atan2(-p.y, p.x);
                float rel = fmod(ang - start, TWO_PI);
                if (rel < 0.0) rel += TWO_PI;
                if (rel > ext) discard_fragment();
            }
        }
    }

    float px_scale = max(u.px_scale, 1e-4);
    float d_px     = d * px_scale;
    bool use_aa    = (in.flags & 1u) != 0u;
    bool is_arc_outline = (in.shape == 3u) && ((in.flags & 6u) == 4u);

    float fa_eff = 0.0;
    if (in.fill_color.a > 0.0 && !is_arc_outline) {
        float fcov = use_aa ? clamp(0.5 - d_px, 0.0, 1.0) : (d_px <= 0.0 ? 1.0 : 0.0);
        fa_eff = in.fill_color.a * fcov;
    }

    float sa_eff = 0.0;
    if (in.stroke_width > 0.0 && in.stroke_color.a > 0.0) {
        float sd   = abs(d_px) - (in.stroke_width * 0.5 * px_scale);
        float scov = use_aa ? clamp(0.5 - sd, 0.0, 1.0) : (sd <= 0.0 ? 1.0 : 0.0);
        sa_eff = in.stroke_color.a * scov;
    }

    float out_a = sa_eff + fa_eff * (1.0 - sa_eff);
    if (out_a <= 0.0) discard_fragment();

    float3 out_rgb = (in.stroke_color.rgb * sa_eff
                    + in.fill_color.rgb * fa_eff * (1.0 - sa_eff)) / out_a;
    return float4(out_rgb, out_a);
}
