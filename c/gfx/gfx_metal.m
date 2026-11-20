/*
 * Tcl::Tk::MT - macOS Metal 2D Graphics Backend (Pure Objective-C, no C++)
 *
 * Manual retain/release safe (also builds cleanly under ARC if enabled).
 * Supports:
 *   - Windowed CAMetalLayer (BGRA8Unorm, HiDPI backingScaleFactor, triple-buffered)
 *     attached to an NSView* native handle
 *   - Headless offscreen MTLTexture (RGBA8Unorm) + exact readback_rgba
 *   - Runtime MSL compilation via newLibraryWithSource: (zero xcrun metal dependency)
 */

#ifdef __APPLE__

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "tkmt_gfx.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#if __has_feature(objc_arc)
#  define TKMT_RELEASE(x) ((void)0)
#  define TKMT_RETAIN(x)  (x)
#else
#  define TKMT_RELEASE(x) do { if (x) { [(x) release]; (x) = nil; } } while (0)
#  define TKMT_RETAIN(x)  ([(x) retain])
#endif

#define TKMT_METAL_FRAMES_IN_FLIGHT 3

typedef struct mtl_frame_uniforms {
    float view_row0[4];
    float view_row1[4];
    float viewport[2];
    float px_scale;
    float _pad;
} mtl_frame_uniforms_t;

typedef struct mtl_tex_slot {
    int               in_use;
    uint32_t          width;
    uint32_t          height;
    tkmt_tex_format_t fmt;
    id<MTLTexture>    tex;
} mtl_tex_slot_t;

typedef struct mtl_pipelines {
    id<MTLRenderPipelineState> solid;
    id<MTLRenderPipelineState> tex_rgba;
    id<MTLRenderPipelineState> glyph_r8;
    id<MTLRenderPipelineState> inst;
} mtl_pipelines_t;

/* Global Metal device & shared compiled pipelines */
static id<MTLDevice>       g_mtl_device  = nil;
static id<MTLCommandQueue> g_mtl_queue   = nil;
static id<MTLLibrary>      g_mtl_lib     = nil;
static id<MTLSamplerState> g_mtl_sampler = nil;
static id<MTLTexture>      g_mtl_white   = nil;
static mtl_pipelines_t     g_pipe_rgba   = { nil, nil, nil, nil };
static mtl_pipelines_t     g_pipe_bgra   = { nil, nil, nil, nil };

/* Dedicated child NSView hosting a CAMetalLayer inside Tk Aqua's root NSView.
 * Passes all mouse and keyboard events straight through to Tk. */
@interface TKMTMetalView : NSView
@end

@implementation TKMTMetalView
- (BOOL)wantsUpdateLayer {
    return YES;
}
+ (Class)layerClass {
    return [CAMetalLayer class];
}
- (CALayer *)makeBackingLayer {
    return [CAMetalLayer layer];
}
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
- (BOOL)acceptsFirstResponder {
    return NO;
}
@end

struct tkmt_gfx_surface {
    uint32_t          width;
    uint32_t          height;
    float             scale;
    int               headless;
    MTLPixelFormat    pixel_format;

    TKMTMetalView    *subview;       /* owned child NSView hosting CAMetalLayer */
    CAMetalLayer     *layer;         /* non-nil when windowed on NSView* */
    id<MTLTexture>    offscreen_tex; /* non-nil when headless */

    id<MTLBuffer>     vb[TKMT_METAL_FRAMES_IN_FLIGHT];
    size_t            vb_cap[TKMT_METAL_FRAMES_IN_FLIGHT];
    id<MTLBuffer>     ib[TKMT_METAL_FRAMES_IN_FLIGHT];
    size_t            ib_cap[TKMT_METAL_FRAMES_IN_FLIGHT];
    uint32_t          frame_idx;

    mtl_tex_slot_t   *textures;
    uint32_t          tex_cap;
};

/* Embedded fallback copy of c/gfx/shaders/canvas2d.metal */
static const char *k_canvas2d_msl_source =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct FrameUniforms {\n"
"    float4 view_row0;\n"
"    float4 view_row1;\n"
"    float2 viewport;\n"
"    float  px_scale;\n"
"    float  _pad;\n"
"};\n"
"struct TkmtVertex {\n"
"    float2 pos;\n"
"    float2 uv;\n"
"    uint   color;\n"
"    uint   flags;\n"
"};\n"
"struct TkmtInstance {\n"
"    float4 rect;\n"
"    uint   fill_color;\n"
"    uint   stroke_color;\n"
"    float  stroke_width;\n"
"    float  param0;\n"
"    float  param1;\n"
"    uint   shape;\n"
"    uint   flags;\n"
"    uint   _pad;\n"
"};\n"
"struct TriOut {\n"
"    float4 position [[position]];\n"
"    float2 uv;\n"
"    float4 color;\n"
"};\n"
"struct InstOut {\n"
"    float4 position [[position]];\n"
"    float2 local_pos;\n"
"    float2 size;\n"
"    float4 fill_color;\n"
"    float4 stroke_color;\n"
"    float  stroke_width;\n"
"    float  param0;\n"
"    float  param1;\n"
"    uint   shape;\n"
"    uint   flags;\n"
"};\n"
"static inline float4 unpack_rgba8(uint c) {\n"
"    return float4(\n"
"        float(c & 0xFFu) / 255.0,\n"
"        float((c >> 8) & 0xFFu) / 255.0,\n"
"        float((c >> 16) & 0xFFu) / 255.0,\n"
"        float((c >> 24) & 0xFFu) / 255.0\n"
"    );\n"
"}\n"
"static inline float2 to_ndc(float2 px, float2 vp) {\n"
"    return float2((px.x / vp.x) * 2.0 - 1.0,\n"
"                  1.0 - (px.y / vp.y) * 2.0);\n"
"}\n"
"vertex TriOut vs_tri(uint vid [[vertex_id]],\n"
"                     const device TkmtVertex *verts [[buffer(0)]],\n"
"                     constant FrameUniforms &u [[buffer(1)]]) {\n"
"    TkmtVertex v = verts[vid];\n"
"    float2 sx = float2(\n"
"        u.view_row0.x * v.pos.x + u.view_row0.y * v.pos.y + u.view_row0.z,\n"
"        u.view_row1.x * v.pos.x + u.view_row1.y * v.pos.y + u.view_row1.z\n"
"    );\n"
"    TriOut out;\n"
"    out.position = float4(to_ndc(sx, u.viewport), 0.0, 1.0);\n"
"    out.uv       = v.uv;\n"
"    out.color    = unpack_rgba8(v.color);\n"
"    return out;\n"
"}\n"
"fragment float4 fs_solid(TriOut in [[stage_in]]) {\n"
"    return in.color;\n"
"}\n"
"fragment float4 fs_tex_rgba(TriOut in [[stage_in]],\n"
"                            texture2d<float> tex [[texture(0)]],\n"
"                            sampler samp [[sampler(0)]]) {\n"
"    float4 t = tex.sample(samp, in.uv);\n"
"    return t * in.color;\n"
"}\n"
"fragment float4 fs_glyph_r8(TriOut in [[stage_in]],\n"
"                            texture2d<float> tex [[texture(0)]],\n"
"                            sampler samp [[sampler(0)]]) {\n"
"    float cov = tex.sample(samp, in.uv).r;\n"
"    if (cov > 0.0 && cov < 1.0) {\n"
"        float luma  = dot(in.color.rgb, float3(0.299, 0.587, 0.114));\n"
"        float t     = clamp((luma - 0.25) / 0.75, 0.0, 1.0);\n"
"        float gamma = mix(1.0, 0.62, t);\n"
"        cov = pow(cov, gamma);\n"
"    }\n"
"    return float4(in.color.rgb, in.color.a * cov);\n"
"}\n"
"vertex InstOut vs_inst(uint vid [[vertex_id]],\n"
"                       uint iid [[instance_id]],\n"
"                       const device TkmtInstance *insts [[buffer(0)]],\n"
"                       constant FrameUniforms &u [[buffer(1)]]) {\n"
"    TkmtInstance inst = insts[iid];\n"
"    float pad = (inst.stroke_width > 0.0 ? inst.stroke_width * 0.5 : 0.0)\n"
"              + (2.0 / max(u.px_scale, 1e-4));\n"
"    const float2 quad[6] = {\n"
"        float2(0.0, 0.0), float2(1.0, 0.0), float2(1.0, 1.0),\n"
"        float2(0.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0)\n"
"    };\n"
"    float2 q = quad[vid];\n"
"    float2 local = float2(\n"
"        mix(-pad, inst.rect.z + pad, q.x),\n"
"        mix(-pad, inst.rect.w + pad, q.y)\n"
"    );\n"
"    float2 world = inst.rect.xy + local;\n"
"    float2 sx = float2(\n"
"        u.view_row0.x * world.x + u.view_row0.y * world.y + u.view_row0.z,\n"
"        u.view_row1.x * world.x + u.view_row1.y * world.y + u.view_row1.z\n"
"    );\n"
"    InstOut out;\n"
"    out.position     = float4(to_ndc(sx, u.viewport), 0.0, 1.0);\n"
"    out.local_pos    = local;\n"
"    out.size         = inst.rect.zw;\n"
"    out.fill_color   = unpack_rgba8(inst.fill_color);\n"
"    out.stroke_color = unpack_rgba8(inst.stroke_color);\n"
"    out.stroke_width = inst.stroke_width;\n"
"    out.param0       = inst.param0;\n"
"    out.param1       = inst.param1;\n"
"    out.shape        = inst.shape;\n"
"    out.flags        = inst.flags;\n"
"    return out;\n"
"}\n"
"fragment float4 fs_inst(InstOut in [[stage_in]],\n"
"                        constant FrameUniforms &u [[buffer(1)]],\n"
"                        texture2d<float> tex [[texture(0)]],\n"
"                        sampler samp [[sampler(0)]]) {\n"
"    if (in.shape == 4u) {\n"
"        if (in.local_pos.x < 0.0 || in.local_pos.x > in.size.x ||\n"
"            in.local_pos.y < 0.0 || in.local_pos.y > in.size.y) {\n"
"            discard_fragment();\n"
"        }\n"
"        float2 uv = in.local_pos / max(in.size, float2(1e-4));\n"
"        float4 t  = tex.sample(samp, uv);\n"
"        float4 m  = (in.fill_color.a > 0.0 || in.fill_color.r > 0.0 ||\n"
"                     in.fill_color.g > 0.0 || in.fill_color.b > 0.0)\n"
"                  ? in.fill_color : float4(1.0);\n"
"        return t * m;\n"
"    }\n"
"    float2 half_sz = in.size * 0.5;\n"
"    float2 p       = in.local_pos - half_sz;\n"
"    float d        = 0.0;\n"
"    if (in.shape == 0u) {\n"
"        float2 q = abs(p) - half_sz;\n"
"        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);\n"
"    } else if (in.shape == 1u) {\n"
"        float r = clamp(in.param0, 0.0, min(half_sz.x, half_sz.y));\n"
"        float2 q = abs(p) - (half_sz - r);\n"
"        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;\n"
"    } else {\n"
"        float2 r = max(half_sz, float2(1e-4));\n"
"        float k0 = length(p / r);\n"
"        float k1 = length(p / (r * r));\n"
"        d = (k1 > 1e-6) ? (k0 * (k0 - 1.0) / k1) : -min(r.x, r.y);\n"
"        if (in.shape == 3u) {\n"
"            float start = in.param0;\n"
"            float ext   = in.param1;\n"
"            if (ext < 0.0) { start += ext; ext = -ext; }\n"
"            const float TWO_PI = 6.28318530717958647692;\n"
"            if (ext < TWO_PI - 1e-4) {\n"
"                float ang = atan2(-p.y, p.x);\n"
"                float rel = fmod(ang - start, TWO_PI);\n"
"                if (rel < 0.0) rel += TWO_PI;\n"
"                if (rel > ext) discard_fragment();\n"
"            }\n"
"        }\n"
"    }\n"
"    float px_scale = max(u.px_scale, 1e-4);\n"
"    float d_px     = d * px_scale;\n"
"    bool use_aa    = (in.flags & 1u) != 0u;\n"
"    bool is_arc_outline = (in.shape == 3u) && ((in.flags & 6u) == 4u);\n"
"    float fa_eff = 0.0;\n"
"    if (in.fill_color.a > 0.0 && !is_arc_outline) {\n"
"        float fcov = use_aa ? clamp(0.5 - d_px, 0.0, 1.0) : (d_px <= 0.0 ? 1.0 : 0.0);\n"
"        fa_eff = in.fill_color.a * fcov;\n"
"    }\n"
"    float sa_eff = 0.0;\n"
"    if (in.stroke_width > 0.0 && in.stroke_color.a > 0.0) {\n"
"        float sd   = abs(d_px) - (in.stroke_width * 0.5 * px_scale);\n"
"        float scov = use_aa ? clamp(0.5 - sd, 0.0, 1.0) : (sd <= 0.0 ? 1.0 : 0.0);\n"
"        sa_eff = in.stroke_color.a * scov;\n"
"    }\n"
"    float out_a = sa_eff + fa_eff * (1.0 - sa_eff);\n"
"    if (out_a <= 0.0) discard_fragment();\n"
"    float3 out_rgb = (in.stroke_color.rgb * sa_eff\n"
"                    + in.fill_color.rgb * fa_eff * (1.0 - sa_eff)) / out_a;\n"
"    return float4(out_rgb, out_a);\n"
"}\n";

static id<MTLRenderPipelineState> make_pipeline(NSString *vs_name,
                                                NSString *fs_name,
                                                MTLPixelFormat fmt) {
    id<MTLFunction> vf = [g_mtl_lib newFunctionWithName:vs_name];
    id<MTLFunction> ff = [g_mtl_lib newFunctionWithName:fs_name];
    if (!vf || !ff) {
        TKMT_RELEASE(vf);
        TKMT_RELEASE(ff);
        return nil;
    }

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction   = vf;
    desc.fragmentFunction = ff;

    MTLRenderPipelineColorAttachmentDescriptor *att = desc.colorAttachments[0];
    att.pixelFormat                 = fmt;
    att.blendingEnabled             = YES;
    att.rgbBlendOperation           = MTLBlendOperationAdd;
    att.sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
    att.destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
    att.alphaBlendOperation         = MTLBlendOperationAdd;
    att.sourceAlphaBlendFactor      = MTLBlendFactorOne;
    att.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    NSError *err = nil;
    id<MTLRenderPipelineState> pso = [g_mtl_device newRenderPipelineStateWithDescriptor:desc
                                                                                  error:&err];
    TKMT_RELEASE(desc);
    TKMT_RELEASE(vf);
    TKMT_RELEASE(ff);
    return pso;
}

static int build_pipelines(mtl_pipelines_t *p, MTLPixelFormat fmt) {
    p->solid    = make_pipeline(@"vs_tri",  @"fs_solid",    fmt);
    p->tex_rgba = make_pipeline(@"vs_tri",  @"fs_tex_rgba", fmt);
    p->glyph_r8 = make_pipeline(@"vs_tri",  @"fs_glyph_r8", fmt);
    p->inst     = make_pipeline(@"vs_inst", @"fs_inst",     fmt);
    return (p->solid && p->tex_rgba && p->glyph_r8 && p->inst) ? 0 : -1;
}

static void release_pipelines(mtl_pipelines_t *p) {
    TKMT_RELEASE(p->solid);
    TKMT_RELEASE(p->tex_rgba);
    TKMT_RELEASE(p->glyph_r8);
    TKMT_RELEASE(p->inst);
}

static int mtl_probe(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return 0;
        TKMT_RELEASE(dev);
        return 1;
    }
}

static int mtl_init(void) {
    @autoreleasepool {
        if (g_mtl_device) return 0;

        g_mtl_device = MTLCreateSystemDefaultDevice();
        if (!g_mtl_device) return -1;

        g_mtl_queue = [g_mtl_device newCommandQueue];
        if (!g_mtl_queue) goto fail;

        NSString *src = [NSString stringWithContentsOfFile:@"c/gfx/shaders/canvas2d.metal"
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        if (!src) {
            src = [NSString stringWithUTF8String:k_canvas2d_msl_source];
        }

        NSError *err = nil;
        g_mtl_lib = [g_mtl_device newLibraryWithSource:src options:nil error:&err];
        if (!g_mtl_lib) goto fail;

        if (build_pipelines(&g_pipe_rgba, MTLPixelFormatRGBA8Unorm) != 0) goto fail;
        if (build_pipelines(&g_pipe_bgra, MTLPixelFormatBGRA8Unorm) != 0) goto fail;

        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter    = MTLSamplerMinMagFilterLinear;
        sd.magFilter    = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        g_mtl_sampler = [g_mtl_device newSamplerStateWithDescriptor:sd];
        TKMT_RELEASE(sd);
        if (!g_mtl_sampler) goto fail;

        MTLTextureDescriptor *wd =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:1
                                                              height:1
                                                           mipmapped:NO];
        wd.storageMode = MTLStorageModeShared;
        wd.usage       = MTLTextureUsageShaderRead;
        g_mtl_white = [g_mtl_device newTextureWithDescriptor:wd];
        if (!g_mtl_white) goto fail;
        uint8_t white_px[4] = { 255, 255, 255, 255 };
        [g_mtl_white replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                       mipmapLevel:0
                         withBytes:white_px
                       bytesPerRow:4];
        return 0;

    fail:
        release_pipelines(&g_pipe_rgba);
        release_pipelines(&g_pipe_bgra);
        TKMT_RELEASE(g_mtl_white);
        TKMT_RELEASE(g_mtl_sampler);
        TKMT_RELEASE(g_mtl_lib);
        TKMT_RELEASE(g_mtl_queue);
        TKMT_RELEASE(g_mtl_device);
        return -1;
    }
}

static void mtl_shutdown(void) {
    @autoreleasepool {
        release_pipelines(&g_pipe_rgba);
        release_pipelines(&g_pipe_bgra);
        TKMT_RELEASE(g_mtl_white);
        TKMT_RELEASE(g_mtl_sampler);
        TKMT_RELEASE(g_mtl_lib);
        TKMT_RELEASE(g_mtl_queue);
        TKMT_RELEASE(g_mtl_device);
    }
}

static id<MTLTexture> create_offscreen_rt(uint32_t w, uint32_t h) {
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [g_mtl_device newTextureWithDescriptor:td];
}

static tkmt_gfx_surface_t *mtl_create_surface(const tkmt_surface_desc_t *desc) {
    if (!g_mtl_device || !desc || desc->width == 0 || desc->height == 0) return NULL;
    @autoreleasepool {
        tkmt_gfx_surface_t *surf = (tkmt_gfx_surface_t *)calloc(1, sizeof(*surf));
        if (!surf) return NULL;

        surf->width    = desc->width;
        surf->height   = desc->height;
        surf->scale    = (desc->scale > 0.0f) ? desc->scale : 1.0f;
        surf->headless = desc->headless;

        if (!desc->headless && desc->handle_type == TKMT_NATIVE_NSVIEW && desc->native_window != 0) {
            NSView *parentView = (NSView *)(void *)desc->native_window;
            CGFloat backing = surf->scale;
            if ([parentView window]) {
                backing = [[parentView window] backingScaleFactor];
            } else if ([NSScreen mainScreen]) {
                backing = [[NSScreen mainScreen] backingScaleFactor];
            }
            if (backing < 1.0) backing = 1.0;
            surf->scale = (float)backing;

            NSRect initFrame = NSMakeRect(0.0, 0.0, (CGFloat)desc->width, (CGFloat)desc->height);
            if (![parentView isFlipped]) {
                CGFloat ph = NSHeight([parentView bounds]);
                initFrame.origin.y = ph - (CGFloat)desc->height;
            }

            TKMTMetalView *subview = [[TKMTMetalView alloc] initWithFrame:initFrame];
            [subview setAutoresizingMask:NSViewNotSizable];
            [subview setWantsLayer:YES];
            [subview setHidden:YES]; /* Shown once Tk maps & positions the Canvas widget */

            CAMetalLayer *layer = (CAMetalLayer *)[subview layer];
            if (![layer isKindOfClass:[CAMetalLayer class]]) {
                layer = [CAMetalLayer layer];
                [subview setLayer:layer];
            }
            layer.device          = g_mtl_device;
            layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
            layer.contentsScale   = backing;
            layer.drawableSize    = CGSizeMake(round((CGFloat)desc->width * backing),
                                               round((CGFloat)desc->height * backing));

            [parentView addSubview:subview];

            surf->subview      = subview; /* retained (+1 from alloc/init) */
            surf->layer        = TKMT_RETAIN(layer);
            surf->pixel_format = MTLPixelFormatBGRA8Unorm;
        } else {
            surf->headless      = 1;
            surf->pixel_format  = MTLPixelFormatRGBA8Unorm;
            surf->offscreen_tex = create_offscreen_rt(desc->width, desc->height);
            if (!surf->offscreen_tex) {
                free(surf);
                return NULL;
            }
        }
        return surf;
    }
}

static void mtl_destroy_surface(tkmt_gfx_surface_t *surf) {
    if (!surf) return;
    @autoreleasepool {
        for (int i = 0; i < TKMT_METAL_FRAMES_IN_FLIGHT; i++) {
            TKMT_RELEASE(surf->vb[i]);
            TKMT_RELEASE(surf->ib[i]);
        }
        if (surf->textures) {
            for (uint32_t i = 0; i < surf->tex_cap; i++) {
                if (surf->textures[i].in_use) {
                    TKMT_RELEASE(surf->textures[i].tex);
                }
            }
            free(surf->textures);
        }
        if (surf->subview) {
            [surf->subview removeFromSuperview];
            TKMT_RELEASE(surf->subview);
        }
        TKMT_RELEASE(surf->offscreen_tex);
        TKMT_RELEASE(surf->layer);
        free(surf);
    }
}

float tkmt_metal_surface_scale(const tkmt_gfx_surface_t *surf);

float tkmt_metal_surface_scale(const tkmt_gfx_surface_t *surf) {
    if (!surf || surf->headless) return 1.0f;
    return (surf->scale >= 1.0f) ? surf->scale : 1.0f;
}

void tkmt_metal_update_subview_rect(void *gfx_surf,
                                    int x, int y, int width, int height,
                                    int visible);

void tkmt_metal_update_subview_rect(void *gfx_surf,
                                    int x, int y, int width, int height,
                                    int visible) {
    tkmt_gfx_surface_t *surf = (tkmt_gfx_surface_t *)gfx_surf;
    if (!surf || surf->headless || !surf->subview) return;

    @autoreleasepool {
        NSView *parentView = [surf->subview superview];
        if (!parentView || !visible || width <= 0 || height <= 0) {
            if (![surf->subview isHidden]) {
                [surf->subview setHidden:YES];
            }
            return;
        }

        CGFloat fy = (CGFloat)y;
        if (![parentView isFlipped]) {
            CGFloat ph = NSHeight([parentView bounds]);
            fy = ph - (CGFloat)(y + height);
        }
        NSRect frame = NSMakeRect((CGFloat)x, fy, (CGFloat)width, (CGFloat)height);
        if (!NSEqualRects([surf->subview frame], frame)) {
            [surf->subview setFrame:frame];
        }
        if ([parentView window]) {
            CGFloat backing = [[parentView window] backingScaleFactor];
            if (backing >= 1.0 && (float)backing != surf->scale) {
                surf->scale = (float)backing;
                if (surf->layer) {
                    surf->layer.contentsScale = backing;
                    surf->layer.drawableSize  = CGSizeMake(
                        round((CGFloat)surf->width * backing),
                        round((CGFloat)surf->height * backing));
                }
            }
        }
        if ([surf->subview isHidden]) {
            [surf->subview setHidden:NO];
        }
    }
}

static int mtl_resize_surface(tkmt_gfx_surface_t *surf,
                              uint32_t width, uint32_t height, float scale) {
    if (!surf || width == 0 || height == 0) return -1;
    @autoreleasepool {
        surf->width  = width;
        surf->height = height;

        if (!surf->headless && surf->layer) {
            CGFloat backing = (surf->scale >= 1.0f) ? (CGFloat)surf->scale : 1.0;
            if (surf->subview && [surf->subview window]) {
                CGFloat wb = [[surf->subview window] backingScaleFactor];
                if (wb >= 1.0) backing = wb;
            } else if (scale > 1.0f) {
                backing = (CGFloat)scale;
            }
            surf->scale = (float)backing;
            surf->layer.contentsScale = backing;
            surf->layer.drawableSize  = CGSizeMake(round((CGFloat)width * backing),
                                                   round((CGFloat)height * backing));
        } else {
            if (scale > 0.0f) surf->scale = scale;
        }
        if (surf->headless) {
            id<MTLTexture> nt = create_offscreen_rt(width, height);
            if (!nt) return -1;
            TKMT_RELEASE(surf->offscreen_tex);
            surf->offscreen_tex = nt;
        }
        return 0;
    }
}

static tkmt_tex_id_t mtl_texture_create(tkmt_gfx_surface_t *surf,
                                        uint32_t width, uint32_t height,
                                        tkmt_tex_format_t fmt,
                                        const uint8_t *pixels) {
    if (!surf || !g_mtl_device || width == 0 || height == 0) return 0;
    @autoreleasepool {
        uint32_t slot = surf->tex_cap;
        for (uint32_t i = 0; i < surf->tex_cap; i++) {
            if (!surf->textures[i].in_use) {
                slot = i;
                break;
            }
        }
        if (slot == surf->tex_cap) {
            uint32_t new_cap = surf->tex_cap ? surf->tex_cap * 2u : 16u;
            mtl_tex_slot_t *arr = (mtl_tex_slot_t *)realloc(surf->textures, new_cap * sizeof(*arr));
            if (!arr) return 0;
            memset(arr + surf->tex_cap, 0, (new_cap - surf->tex_cap) * sizeof(*arr));
            surf->textures = arr;
            surf->tex_cap  = new_cap;
        }

        MTLPixelFormat pfmt = (fmt == TKMT_TEX_R8) ? MTLPixelFormatR8Unorm : MTLPixelFormatRGBA8Unorm;
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pfmt
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage       = MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [g_mtl_device newTextureWithDescriptor:td];
        if (!tex) return 0;

        size_t bpp = (fmt == TKMT_TEX_R8) ? 1u : 4u;
        if (pixels) {
            [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
                   mipmapLevel:0
                     withBytes:pixels
                   bytesPerRow:width * bpp];
        } else {
            size_t bytes = (size_t)width * (size_t)height * bpp;
            uint8_t *zero = (uint8_t *)calloc(1, bytes);
            if (zero) {
                [tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
                       mipmapLevel:0
                         withBytes:zero
                       bytesPerRow:width * bpp];
                free(zero);
            }
        }

        surf->textures[slot].in_use = 1;
        surf->textures[slot].width  = width;
        surf->textures[slot].height = height;
        surf->textures[slot].fmt    = fmt;
        surf->textures[slot].tex    = tex;
        return slot + 1u;
    }
}

static int mtl_texture_update(tkmt_gfx_surface_t *surf, tkmt_tex_id_t tex_id,
                              uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                              const uint8_t *pixels) {
    if (!surf || !pixels || tex_id == 0 || tex_id > surf->tex_cap) return -1;
    mtl_tex_slot_t *slot = &surf->textures[tex_id - 1];
    if (!slot->in_use || !slot->tex || x + w > slot->width || y + h > slot->height) return -1;
    @autoreleasepool {
        size_t bpp = (slot->fmt == TKMT_TEX_R8) ? 1u : 4u;
        [slot->tex replaceRegion:MTLRegionMake2D(x, y, w, h)
                     mipmapLevel:0
                       withBytes:pixels
                     bytesPerRow:w * bpp];
        return 0;
    }
}

static void mtl_texture_destroy(tkmt_gfx_surface_t *surf, tkmt_tex_id_t tex_id) {
    if (!surf || tex_id == 0 || tex_id > surf->tex_cap) return;
    mtl_tex_slot_t *slot = &surf->textures[tex_id - 1];
    if (slot->in_use) {
        @autoreleasepool {
            TKMT_RELEASE(slot->tex);
            memset(slot, 0, sizeof(*slot));
        }
    }
}

static id<MTLBuffer> ensure_shared_buf(id<MTLBuffer> *slot, size_t *cap, size_t needed) {
    if (needed == 0) return nil;
    if (*slot && *cap >= needed) return *slot;
    size_t alloc_sz = needed;
    if (alloc_sz < 4096) alloc_sz = 4096;
    id<MTLBuffer> nb = [g_mtl_device newBufferWithLength:alloc_sz
                                                 options:MTLResourceStorageModeShared];
    if (!nb) return nil;
    TKMT_RELEASE(*slot);
    *slot = nb;
    *cap  = alloc_sz;
    return nb;
}

static id<MTLTexture> lookup_tex(const tkmt_gfx_surface_t *surf, tkmt_tex_id_t id) {
    if (id == 0 || id > surf->tex_cap) return g_mtl_white;
    if (!surf->textures[id - 1].in_use || !surf->textures[id - 1].tex) return g_mtl_white;
    return surf->textures[id - 1].tex;
}

static int mtl_render(tkmt_gfx_surface_t *surf, const tkmt_draw_list_t *list) {
    if (!surf || !list || !g_mtl_queue) return -1;
    @autoreleasepool {
        id<CAMetalDrawable> drawable = nil;
        id<MTLTexture> target_tex    = nil;
        if (surf->headless) {
            target_tex = surf->offscreen_tex;
        } else if (surf->layer) {
            drawable = [surf->layer nextDrawable];
            if (!drawable) return -1;
            target_tex = drawable.texture;
        }
        if (!target_tex) return -1;

        uint32_t fi = surf->frame_idx % TKMT_METAL_FRAMES_IN_FLIGHT;
        surf->frame_idx++;

        id<MTLBuffer> vbuf = nil;
        if (list->vertex_count > 0 && list->vertices) {
            size_t vbytes = (size_t)list->vertex_count * sizeof(tkmt_vertex_t);
            vbuf = ensure_shared_buf(&surf->vb[fi], &surf->vb_cap[fi], vbytes);
            if (!vbuf) return -1;
            memcpy([vbuf contents], list->vertices, vbytes);
        }

        id<MTLBuffer> ibuf = nil;
        if (list->instance_count > 0 && list->instances) {
            size_t ibytes = (size_t)list->instance_count * sizeof(tkmt_instance_t);
            ibuf = ensure_shared_buf(&surf->ib[fi], &surf->ib_cap[fi], ibytes);
            if (!ibuf) return -1;
            memcpy([ibuf contents], list->instances, ibytes);
        }

        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        MTLRenderPassColorAttachmentDescriptor *att = rpd.colorAttachments[0];
        att.texture     = target_tex;
        att.storeAction = MTLStoreActionStore;
        if (list->do_clear) {
            att.loadAction = MTLLoadActionClear;
            att.clearColor = MTLClearColorMake(
                (double)tkmt_rgba_r(list->clear_color) / 255.0,
                (double)tkmt_rgba_g(list->clear_color) / 255.0,
                (double)tkmt_rgba_b(list->clear_color) / 255.0,
                (double)tkmt_rgba_a(list->clear_color) / 255.0
            );
        } else {
            att.loadAction = MTLLoadActionLoad;
        }

        id<MTLCommandBuffer> cb = [g_mtl_queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];

        NSUInteger rt_w = [target_tex width];
        NSUInteger rt_h = [target_tex height];
        MTLViewport vp = { 0.0, 0.0, (double)rt_w, (double)rt_h, 0.0, 1.0 };
        [enc setViewport:vp];

        float fb_sx = (surf->width > 0)  ? ((float)rt_w / (float)surf->width)  : 1.0f;
        float fb_sy = (surf->height > 0) ? ((float)rt_h / (float)surf->height) : 1.0f;
        float fb_scale = 0.5f * (fb_sx + fb_sy);
        if (fb_scale < 1e-4f) fb_scale = 1.0f;

        const float *m = list->view_matrix;
        float sx_len = sqrtf(m[0]*m[0] + m[3]*m[3]);
        float sy_len = sqrtf(m[1]*m[1] + m[4]*m[4]);
        float px_scale = 0.5f * (sx_len + sy_len);
        if (px_scale < 1e-4f) px_scale = 1.0f;

        mtl_frame_uniforms_t uni;
        uni.view_row0[0] = m[0]; uni.view_row0[1] = m[1]; uni.view_row0[2] = m[2]; uni.view_row0[3] = 0.0f;
        uni.view_row1[0] = m[3]; uni.view_row1[1] = m[4]; uni.view_row1[2] = m[5]; uni.view_row1[3] = 0.0f;
        uni.viewport[0]  = (float)surf->width;
        uni.viewport[1]  = (float)surf->height;
        uni.px_scale     = px_scale * fb_scale;
        uni._pad         = 0.0f;

        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:1];
        [enc setFragmentSamplerState:g_mtl_sampler atIndex:0];

        const mtl_pipelines_t *pipes = (surf->pixel_format == MTLPixelFormatBGRA8Unorm)
                                     ? &g_pipe_bgra : &g_pipe_rgba;

        uint64_t total_verts = 0;
        uint64_t total_insts = 0;

        for (uint32_t ci = 0; ci < list->cmd_count; ci++) {
            const tkmt_draw_cmd_t *cmd = &list->cmds[ci];
            if (cmd->count == 0) continue;

            MTLScissorRect sc = { 0, 0, rt_w, rt_h };
            if (cmd->clip.w > 0 && cmd->clip.h > 0) {
                int32_t x0 = (int32_t)floorf((float)cmd->clip.x * fb_sx);
                int32_t y0 = (int32_t)floorf((float)cmd->clip.y * fb_sy);
                int32_t x1 = (int32_t)ceilf((float)(cmd->clip.x + cmd->clip.w) * fb_sx);
                int32_t y1 = (int32_t)ceilf((float)(cmd->clip.y + cmd->clip.h) * fb_sy);
                if (x0 < 0) x0 = 0;
                if (y0 < 0) y0 = 0;
                if (x1 > (int32_t)rt_w) x1 = (int32_t)rt_w;
                if (y1 > (int32_t)rt_h) y1 = (int32_t)rt_h;
                if (x0 >= x1 || y0 >= y1) continue;
                sc.x = (NSUInteger)x0;
                sc.y = (NSUInteger)y0;
                sc.width  = (NSUInteger)(x1 - x0);
                sc.height = (NSUInteger)(y1 - y0);
            }
            [enc setScissorRect:sc];

            if (cmd->type == TKMT_CMD_INSTANCES) {
                if (!ibuf || cmd->first >= list->instance_count) continue;
                uint32_t cnt = cmd->count;
                if (cmd->first + cnt > list->instance_count) {
                    cnt = list->instance_count - cmd->first;
                }
                [enc setRenderPipelineState:pipes->inst];
                [enc setVertexBuffer:ibuf offset:0 atIndex:0];
                [enc setFragmentTexture:lookup_tex(surf, cmd->tex_id) atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle
                        vertexStart:0
                        vertexCount:6
                      instanceCount:cnt
                       baseInstance:cmd->first];
                total_insts += cnt;
            } else {
                if (!vbuf || cmd->first >= list->vertex_count) continue;
                uint32_t cnt = cmd->count;
                if (cmd->first + cnt > list->vertex_count) {
                    cnt = list->vertex_count - cmd->first;
                }
                if (cmd->type == TKMT_CMD_TRIANGLES) {
                    [enc setRenderPipelineState:pipes->solid];
                } else if (cmd->type == TKMT_CMD_TEXTURED_TRIANGLES) {
                    [enc setRenderPipelineState:pipes->tex_rgba];
                    [enc setFragmentTexture:lookup_tex(surf, cmd->tex_id) atIndex:0];
                } else {
                    [enc setRenderPipelineState:pipes->glyph_r8];
                    [enc setFragmentTexture:lookup_tex(surf, cmd->tex_id) atIndex:0];
                }
                [enc setVertexBuffer:vbuf offset:0 atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle
                        vertexStart:cmd->first
                        vertexCount:cnt];
                total_verts += cnt;
            }
        }

        [enc endEncoding];
        if (drawable) {
            [cb presentDrawable:drawable];
        }
        [cb commit];
        if (surf->headless) {
            [cb waitUntilCompleted];
        }

        tkmt_gfx_record_frame("metal", list->cmd_count, total_verts, total_insts, 0);
        return 0;
    }
}

static int mtl_readback_rgba(tkmt_gfx_surface_t *surf, uint8_t *out_rgba, size_t buf_bytes) {
    if (!surf || !out_rgba || !surf->offscreen_tex) return -1;
    size_t needed = (size_t)surf->width * (size_t)surf->height * 4u;
    if (buf_bytes < needed) return -1;
    @autoreleasepool {
        [surf->offscreen_tex getBytes:out_rgba
                          bytesPerRow:(NSUInteger)surf->width * 4u
                           fromRegion:MTLRegionMake2D(0, 0, surf->width, surf->height)
                          mipmapLevel:0];
        tkmt_gfx_record_readback();
        return 0;
    }
}

static const tkmt_gfx_backend_t g_metal_backend = {
    .id              = TKMT_GFX_BACKEND_METAL,
    .name            = "metal",
    .description     = "macOS Apple Metal GPU backend (CAMetalLayer + offscreen readback)",
    .device_class    = TKMT_GFX_DEV_GPU,
    .priority        = 100,
    .caps            = TKMT_GFX_CAP_OFFSCREEN
                     | TKMT_GFX_CAP_WINDOWED
                     | TKMT_GFX_CAP_INSTANCING
                     | TKMT_GFX_CAP_SDF
                     | TKMT_GFX_CAP_GLYPH_ATLAS
                     | TKMT_GFX_CAP_RGBA_TEXTURE
                     | TKMT_GFX_CAP_HIDPI,
    .probe           = mtl_probe,
    .init            = mtl_init,
    .shutdown        = mtl_shutdown,
    .create_surface  = mtl_create_surface,
    .destroy_surface = mtl_destroy_surface,
    .resize_surface  = mtl_resize_surface,
    .texture_create  = mtl_texture_create,
    .texture_update  = mtl_texture_update,
    .texture_destroy = mtl_texture_destroy,
    .render          = mtl_render,
    .readback_rgba   = mtl_readback_rgba
};

const tkmt_gfx_backend_t *tkmt_gfx_get_metal_backend(void) {
    return &g_metal_backend;
}

#endif /* __APPLE__ */
