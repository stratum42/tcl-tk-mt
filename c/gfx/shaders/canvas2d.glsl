/*
 * Tcl::Tk::MT - Vulkan GLSL 450 2D Canvas Shaders
 *
 * Compile to SPIR-V headers with:
 *   glslangValidator -V -S vert -DTKMT_STAGE_VS_TRI  -o vs_tri.spv  canvas2d.glsl
 *   glslangValidator -V -S frag -DTKMT_STAGE_FS_SOLID -o fs_solid.spv canvas2d.glsl
 *   glslangValidator -V -S frag -DTKMT_STAGE_FS_TEX   -o fs_tex.spv   canvas2d.glsl
 *   glslangValidator -V -S frag -DTKMT_STAGE_FS_GLYPH -o fs_glyph.spv canvas2d.glsl
 *   glslangValidator -V -S vert -DTKMT_STAGE_VS_INST  -o vs_inst.spv  canvas2d.glsl
 *   glslangValidator -V -S frag -DTKMT_STAGE_FS_INST  -o fs_inst.spv  canvas2d.glsl
 */
#version 450

layout(push_constant) uniform FrameUniforms {
    vec4 view_row0; /* m[0], m[1], m[2], 0 */
    vec4 view_row1; /* m[3], m[4], m[5], 0 */
    vec2 viewport;  /* width, height */
    float px_scale;
    float _pad;
} u;

vec4 unpack_rgba8(uint c) {
    return vec4(
        float(c & 0xFFu) / 255.0,
        float((c >> 8) & 0xFFu) / 255.0,
        float((c >> 16) & 0xFFu) / 255.0,
        float((c >> 24) & 0xFFu) / 255.0
    );
}

vec2 to_ndc(vec2 px, vec2 vp) {
    /* Vulkan NDC: top-left is (-1, -1), bottom-right is (+1, +1) */
    return vec2((px.x / vp.x) * 2.0 - 1.0,
                (px.y / vp.y) * 2.0 - 1.0);
}

#if defined(TKMT_STAGE_VS_TRI)
layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in uint in_color;
layout(location = 3) in uint in_flags;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

void main() {
    vec2 sx = vec2(
        u.view_row0.x * in_pos.x + u.view_row0.y * in_pos.y + u.view_row0.z,
        u.view_row1.x * in_pos.x + u.view_row1.y * in_pos.y + u.view_row1.z
    );
    gl_Position = vec4(to_ndc(sx, u.viewport), 0.0, 1.0);
    v_uv        = in_uv;
    v_color     = unpack_rgba8(in_color);
}
#endif

#if defined(TKMT_STAGE_FS_SOLID)
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = v_color;
}
#endif

#if defined(TKMT_STAGE_FS_TEX)
layout(set = 0, binding = 0) uniform sampler2D u_tex;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(u_tex, v_uv) * v_color;
}
#endif

#if defined(TKMT_STAGE_FS_GLYPH)
layout(set = 0, binding = 0) uniform sampler2D u_tex;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;
layout(location = 0) out vec4 out_color;

void main() {
    float cov = texture(u_tex, v_uv).r;
    if (cov > 0.0 && cov < 1.0) {
        float luma  = dot(v_color.rgb, vec3(0.299, 0.587, 0.114));
        float t     = clamp((luma - 0.25) / 0.75, 0.0, 1.0);
        float gamma = mix(1.0, 0.62, t);
        cov = pow(cov, gamma);
    }
    out_color = vec4(v_color.rgb, v_color.a * cov);
}
#endif

#if defined(TKMT_STAGE_VS_INST)
struct TkmtInstance {
    vec4  rect;
    uint  fill_color;
    uint  stroke_color;
    float stroke_width;
    float param0;
    float param1;
    uint  shape;
    uint  flags;
    uint  _pad;
};

layout(std430, set = 0, binding = 1) readonly buffer InstanceBuf {
    TkmtInstance insts[];
};

layout(location = 0) out vec2 v_local;
layout(location = 1) out vec2 v_size;
layout(location = 2) out vec4 v_fill;
layout(location = 3) out vec4 v_stroke;
layout(location = 4) out vec3 v_params; /* stroke_width, param0, param1 */
layout(location = 5) flat out uvec2 v_meta; /* shape, flags */

void main() {
    TkmtInstance inst = insts[gl_InstanceIndex];
    float pad = (inst.stroke_width > 0.0 ? inst.stroke_width * 0.5 : 0.0)
              + (2.0 / max(u.px_scale, 1e-4));
    const vec2 quad[6] = vec2[6](
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
        vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0)
    );
    vec2 q = quad[gl_VertexIndex];
    vec2 local = vec2(
        mix(-pad, inst.rect.z + pad, q.x),
        mix(-pad, inst.rect.w + pad, q.y)
    );
    vec2 world = inst.rect.xy + local;
    vec2 sx = vec2(
        u.view_row0.x * world.x + u.view_row0.y * world.y + u.view_row0.z,
        u.view_row1.x * world.x + u.view_row1.y * world.y + u.view_row1.z
    );
    gl_Position = vec4(to_ndc(sx, u.viewport), 0.0, 1.0);
    v_local     = local;
    v_size      = inst.rect.zw;
    v_fill      = unpack_rgba8(inst.fill_color);
    v_stroke    = unpack_rgba8(inst.stroke_color);
    v_params    = vec3(inst.stroke_width, inst.param0, inst.param1);
    v_meta      = uvec2(inst.shape, inst.flags);
}
#endif

#if defined(TKMT_STAGE_FS_INST)
layout(set = 0, binding = 0) uniform sampler2D u_tex;
layout(location = 0) in vec2 v_local;
layout(location = 1) in vec2 v_size;
layout(location = 2) in vec4 v_fill;
layout(location = 3) in vec4 v_stroke;
layout(location = 4) in vec3 v_params;
layout(location = 5) flat in uvec2 v_meta;
layout(location = 0) out vec4 out_color;

void main() {
    uint shape = v_meta.x;
    uint flags = v_meta.y;

    if (shape == 4u) {
        if (v_local.x < 0.0 || v_local.x > v_size.x ||
            v_local.y < 0.0 || v_local.y > v_size.y) {
            discard;
        }
        vec2 uv = v_local / max(v_size, vec2(1e-4));
        vec4 t  = texture(u_tex, uv);
        vec4 m  = (v_fill.a > 0.0 || v_fill.r > 0.0 || v_fill.g > 0.0 || v_fill.b > 0.0)
                ? v_fill : vec4(1.0);
        out_color = t * m;
        return;
    }

    vec2 half_sz = v_size * 0.5;
    vec2 p       = v_local - half_sz;
    float d      = 0.0;

    if (shape == 0u) {
        vec2 q = abs(p) - half_sz;
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    } else if (shape == 1u) {
        float r = clamp(v_params.y, 0.0, min(half_sz.x, half_sz.y));
        vec2 q  = abs(p) - (half_sz - r);
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    } else {
        vec2 r   = max(half_sz, vec2(1e-4));
        float k0 = length(p / r);
        float k1 = length(p / (r * r));
        d = (k1 > 1e-6) ? (k0 * (k0 - 1.0) / k1) : -min(r.x, r.y);

        if (shape == 3u) {
            float start = v_params.y;
            float ext   = v_params.z;
            if (ext < 0.0) { start += ext; ext = -ext; }
            const float TWO_PI = 6.28318530717958647692;
            if (ext < TWO_PI - 1e-4) {
                float ang = atan(-p.y, p.x);
                float rel = mod(ang - start, TWO_PI);
                if (rel > ext) discard;
            }
        }
    }

    float px_scale = max(u.px_scale, 1e-4);
    float d_px     = d * px_scale;
    bool use_aa    = (flags & 1u) != 0u;
    bool is_arc_outline = (shape == 3u) && ((flags & 6u) == 4u);

    float fa_eff = 0.0;
    if (v_fill.a > 0.0 && !is_arc_outline) {
        float fcov = use_aa ? clamp(0.5 - d_px, 0.0, 1.0) : (d_px <= 0.0 ? 1.0 : 0.0);
        fa_eff = v_fill.a * fcov;
    }

    float sa_eff = 0.0;
    if (v_params.x > 0.0 && v_stroke.a > 0.0) {
        float sd   = abs(d_px) - (v_params.x * 0.5 * px_scale);
        float scov = use_aa ? clamp(0.5 - sd, 0.0, 1.0) : (sd <= 0.0 ? 1.0 : 0.0);
        sa_eff = v_stroke.a * scov;
    }

    float out_a = sa_eff + fa_eff * (1.0 - sa_eff);
    if (out_a <= 0.0) discard;

    vec3 out_rgb = (v_stroke.rgb * sa_eff + v_fill.rgb * fa_eff * (1.0 - sa_eff)) / out_a;
    out_color = vec4(out_rgb, out_a);
}
#endif
