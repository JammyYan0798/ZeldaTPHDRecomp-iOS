// Presentation reused from this fork's gfx/display.mm (MPL-2.0).
// UIKit supplies the layer; preserve the TP screen composition and colour conversion.
// ---------------------------------------------------------------- presentation shader
static const char* kPresentShader = R"(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut present_vs(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);          // fullscreen triangle strip corners
    VOut o;
    o.uv = p * 0.5;                                       // 0..1 (flipped below)
    float2 ndc = rect.xy + p * 0.5 * rect.zw;
    o.pos = float4(ndc.x * 2.0 - 1.0, 1.0 - ndc.y * 2.0, 0.0, 1.0);
    return o;
}
// optional edge smoothing (FXAA, the classic console variant), evaluated on the source picture's
// texel grid while scaling it to the window
static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }
static float3 fxaa(texture2d<float> t, sampler s, float2 uv) {
    float2 rcp = 1.0 / float2(t.get_width(), t.get_height());
    float3 nw = t.sample(s, uv + float2(-1, -1) * rcp).rgb, ne = t.sample(s, uv + float2(1, -1) * rcp).rgb;
    float3 sw = t.sample(s, uv + float2(-1, 1) * rcp).rgb, se = t.sample(s, uv + float2(1, 1) * rcp).rgb;
    float3 m = t.sample(s, uv).rgb;
    float lnw = luma(nw), lne = luma(ne), lsw = luma(sw), lse = luma(se), lm = luma(m);
    float lmin = min(lm, min(min(lnw, lne), min(lsw, lse))), lmax = max(lm, max(max(lnw, lne), max(lsw, lse)));
    if (lmax - lmin < max(0.0312, lmax * 0.125)) return m;  // no edge here
    float2 dir = float2(-((lnw + lne) - (lsw + lse)), (lnw + lsw) - (lne + lse));
    float reduce = max((lnw + lne + lsw + lse) * (0.25 / 8.0), 1.0 / 128.0);
    dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), -8.0, 8.0) * rcp;
    float3 a = 0.5 * (t.sample(s, uv + dir * (1.0 / 3.0 - 0.5)).rgb + t.sample(s, uv + dir * (2.0 / 3.0 - 0.5)).rgb);
    float3 b = a * 0.5 + 0.25 * (t.sample(s, uv - dir * 0.5).rgb + t.sample(s, uv + dir * 0.5).rgb);
    float lb = luma(b);
    return (lb < lmin || lb > lmax) ? a : b;
}
struct Params {
    int aa;          // FXAA
    int conv;        // 1: source is display-encoded, target expects linear; 2: the other way round
    float sharp;     // > 1: sharp bilinear (the blend band between texels shrinks by this factor)
    float foot;      // source texels per target pixel (> 1: 4-tap box filter when shrinking)
};
static float3 to_linear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
static float3 to_srgb(float3 c) { return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }
fragment float4 present_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                           constant Params& p [[buffer(0)]]) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 uv = in.uv;
    if (p.sharp > 1.0) {
        float2 t = uv * size - 0.5, i = floor(t), f = t - i;
        f = clamp((f - 0.5) * p.sharp + 0.5, 0.0, 1.0);
        uv = (i + f + 0.5) / size;
    }
    float3 c;
    if (p.aa) {
        c = fxaa(tex, s, uv);
    } else if (p.foot > 1.25) {
        float2 d = 0.25 * min(p.foot, 4.0) / size;
        c = 0.25 * (tex.sample(s, uv + float2(-d.x, -d.y)).rgb + tex.sample(s, uv + float2(d.x, -d.y)).rgb +
                    tex.sample(s, uv + float2(-d.x, d.y)).rgb + tex.sample(s, uv + float2(d.x, d.y)).rgb);
    } else {
        c = tex.sample(s, uv).rgb;
    }
    if (p.conv == 1) c = to_linear(saturate(c));
    else if (p.conv == 2) c = to_srgb(saturate(c));
    return float4(c, 1.0);
}
fragment float4 solid_fs(VOut in [[stage_in]], constant float4& color [[buffer(0)]]) { return color; }
)";

static id<MTLLibrary> g_lib;
// pipelines by (target format, solid colour, blended)
static id<MTLRenderPipelineState> pipeline(MTLPixelFormat fmt, bool solid, bool blend) {
    static std::mutex mu;
    static std::map<std::tuple<int, bool, bool>, id<MTLRenderPipelineState>> cache;
    std::lock_guard<std::mutex> lk(mu);
    auto key = std::make_tuple((int)fmt, solid, blend);
    auto it = cache.find(key);
    if (it != cache.end()) return it->second;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [g_lib newFunctionWithName:@"present_vs"];
    d.fragmentFunction = [g_lib newFunctionWithName:solid ? @"solid_fs" : @"present_fs"];
    d.colorAttachments[0].pixelFormat = fmt;
    if (blend) {
        // overlay opacity: the encoder's blend colour alpha (solid: the colour's alpha)
        auto* a = d.colorAttachments[0];
        a.blendingEnabled = YES;
        a.sourceRGBBlendFactor = a.sourceAlphaBlendFactor = solid ? MTLBlendFactorSourceAlpha : MTLBlendFactorBlendAlpha;
        a.destinationRGBBlendFactor = a.destinationAlphaBlendFactor =
            solid ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOneMinusBlendAlpha;
    }
    NSError* err = nil;
    id<MTLRenderPipelineState> p = [R.device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) fatal("present pipeline: %s", err.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

static void create_present_pipeline() {
    NSError* err = nil;
    g_lib = [R.device newLibraryWithSource:[NSString stringWithUTF8String:kPresentShader] options:nil error:&err];
    if (!g_lib) fatal("present shader: %s", err.localizedDescription.UTF8String);
    R.presentPipeline = pipeline(MTLPixelFormatBGRA8Unorm, false, false);
    R.presentPipelineSRGB = pipeline(MTLPixelFormatBGRA8Unorm_sRGB, false, false);
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    R.linearClamp = [R.device newSamplerStateWithDescriptor:sd];
}

// ---------------------------------------------------------------- composition
static bool is_srgb(MTLPixelFormat f) { return f == MTLPixelFormatBGRA8Unorm_sRGB || f == MTLPixelFormatRGBA8Unorm_sRGB; }

// draw `tex` into the target rectangle (pixels); src_linear: the image holds linear values (sRGB scan buffer)
static void draw_image(id<MTLRenderCommandEncoder> e, MTLPixelFormat fmt, float dw, float dh, id<MTLTexture> tex,
                       bool src_linear, Box b, float alpha) {
    if (!tex || b.w <= 0 || b.h <= 0) return;
    float rect[4] = {b.x / dw, b.y / dh, b.w / dw, b.h / dh};
    bool blend = alpha < 0.999f;
    [e setRenderPipelineState:pipeline(fmt, false, blend)];
    if (blend) [e setBlendColorRed:0 green:0 blue:0 alpha:alpha];
    struct { int aa, conv; float sharp, foot; } p;
    p.aa = fxaa_enabled() ? 1 : 0;
    bool dst_linear = is_srgb(fmt);
    p.conv = src_linear == dst_linear ? 0 : dst_linear ? 1 : 2;
    float scale = std::min(b.w / tex.width, b.h / tex.height);  // target pixels per source texel
    int filter = g_filter;
    p.sharp = filter == kSmooth || scale <= 1.0f ? 1.0f : filter == kSharp ? scale : 1e4f;
    p.foot = scale < 1.0f ? 1.0f / scale : 1.0f;
    [e setVertexBytes:rect length:sizeof rect atIndex:0];
    [e setFragmentTexture:tex atIndex:0];
    [e setFragmentBytes:&p length:sizeof p atIndex:0];
    [e setFragmentSamplerState:R.linearClamp atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

static void draw_solid(id<MTLRenderCommandEncoder> e, MTLPixelFormat fmt, float dw, float dh, Box b, const float rgba[4]) {
    float rect[4] = {b.x / dw, b.y / dh, b.w / dw, b.h / dh};
    [e setRenderPipelineState:pipeline(fmt, true, true)];
    [e setVertexBytes:rect length:sizeof rect atIndex:0];
    [e setFragmentBytes:rgba length:16 atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

// this frame's settings overlay (null: nothing shown)
static ImDrawData* g_overlay_draw = nullptr;
static void overlay_metal_init() { ImGui_ImplMetal_Init(R.device); }

// the TV window's picture: TV image scaled to fit, GamePad overlay on top
static id<MTLTexture> spatial_tv_texture(const Layout& L) {
    id<MTLTexture> source = R.tv.tex;
    if (!source || L.drc_only || !spatial_upscale_enabled() || L.tv.w < 1 || L.tv.h < 1) return source;
    NSUInteger outputWidth = (NSUInteger)roundf(L.tv.w), outputHeight = (NSUInteger)roundf(L.tv.h);
    // A 1x or smaller presentation needs only the normal sampler; MetalFX requires enlargement on both axes.
    if (outputWidth <= source.width || outputHeight <= source.height) return source;

    // MetalFX encodes work on this frame's command buffer. End any active game render encoder first.
    end_encoder();
    id<MTLTexture> output = spatial_upscale(R.device, command_buffer(), source, outputWidth, outputHeight);
    if (!output && spatial_upscale_failed()) request_spatial_upscale_native_fallback();
    return output ?: source;
}

static void compose_tv(id<MTLTexture> target, const Layout& L, id<MTLTexture> tvTexture) {
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    float dw = target.width, dh = target.height;
    MTLPixelFormat fmt = target.pixelFormat;
    draw_image(e, fmt, dw, dh, tvTexture, R.tv.srgb, L.tv, 1.0f);
    if (aspect::full_menu()) {  // black beside a full-screen menu drawn at 16:9 (aspect.cpp), not the game world
        const float side = L.tv.w * (1 - 16.0f / 9.0f / aspect::game()) / 2, black[4] = {0, 0, 0, 1};
        draw_solid(e, fmt, dw, dh, {L.tv.x, L.tv.y, side, L.tv.h}, black);
        draw_solid(e, fmt, dw, dh, {L.tv.x + L.tv.w - side, L.tv.y, side, L.tv.h}, black);
    }
    if (L.pip_on && R.drc.tex) {
        float op = L.drc_only ? 1.0f : g_pip_opacity.load(), bw = std::max(1.0f, roundf(L.pip.w / 200.0f));
        float frame[4] = {0, 0, 0, 0.6f * op};
        draw_solid(e, fmt, dw, dh, {L.pip.x - bw, L.pip.y - bw, L.pip.w + 2 * bw, L.pip.h + 2 * bw}, frame);
        draw_image(e, fmt, dw, dh, R.drc.tex, R.drc.srgb, L.pip, op);
    }
    // settings overlay (overlay/overlay.h) on top: Dear ImGui's Metal backend in the same pass
    if (g_overlay_draw) {
        if (is_srgb(fmt)) overlay::linearize_colors(g_overlay_draw);
        ImGui_ImplMetal_NewFrame(rp);
        ImGui_ImplMetal_RenderDrawData(g_overlay_draw, command_buffer(), e);
    }
    [e endEncoding];
}

static void compose_drc(id<MTLTexture> target) {
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    Layout L = layout(target.width, target.height, R.drc.tex.width, R.drc.tex.height, 0, 0, false);
    draw_image(e, target.pixelFormat, target.width, target.height, R.drc.tex, R.drc.srgb, L.tv, 1.0f);
    [e endEncoding];
}

// ---------------------------------------------------------------- automatic overlay
// Every 4th frame both pictures are reduced to 32x18 (mipmapped copy, then a trilinear draw, display-
// encoded RGBA8) and read back; display_auto_signature (display_modes.cpp) decides.
namespace {
const uint32_t kSigW = 32, kSigH = 18, kSigN = kSigW * kSigH;
struct Sig {
    id<MTLTexture> mip, small;
    id<MTLBuffer> buf;
    // encode the reduction of `src` (on the current command buffer)
    void encode(id<MTLTexture> src, bool src_linear) {
        if (!mip || mip.width != src.width || mip.height != src.height || mip.pixelFormat != src.pixelFormat) {
            MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:src.width
                                                                                         height:src.height mipmapped:YES];
            d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            d.storageMode = MTLStorageModePrivate;
            mip = [R.device newTextureWithDescriptor:d];
        }
        if (!small) {
            MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:kSigW
                                                                                         height:kSigH mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget;
            d.storageMode = MTLStorageModePrivate;
            small = [R.device newTextureWithDescriptor:d];
            buf = [R.device newBufferWithLength:kSigN * 4 options:MTLResourceStorageModeShared];
        }
        static id<MTLSamplerState> trilinear = [] {
            MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
            sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
            sd.mipFilter = MTLSamplerMipFilterLinear;
            sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
            return [R.device newSamplerStateWithDescriptor:sd];
        }();
        id<MTLBlitCommandEncoder> b = [command_buffer() blitCommandEncoder];
        [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(src.width, src.height, 1) toTexture:mip destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b generateMipmapsForTexture:mip];
        [b endEncoding];
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = small;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
        float rect[4] = {0, 0, 1, 1};
        struct { int aa, conv; float sharp, foot; } p = {0, src_linear ? 2 : 0, 1.0f, 1.0f};
        [e setRenderPipelineState:pipeline(MTLPixelFormatRGBA8Unorm, false, false)];
        [e setVertexBytes:rect length:sizeof rect atIndex:0];
        [e setFragmentTexture:mip atIndex:0];
        [e setFragmentBytes:&p length:sizeof p atIndex:0];
        [e setFragmentSamplerState:trilinear atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [e endEncoding];
        b = [command_buffer() blitCommandEncoder];
        [b copyFromTexture:small sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(kSigW, kSigH, 1)
                  toBuffer:buf destinationOffset:0 destinationBytesPerRow:kSigW * 4 destinationBytesPerImage:kSigN * 4];
        [b endEncoding];
    }
    std::vector<float> luma() const {
        std::vector<float> v(kSigN);
        const uint8_t* px = (const uint8_t*)buf.contents;
        for (uint32_t i = 0; i < kSigN; i++) v[i] = (0.299f * px[i * 4] + 0.587f * px[i * 4 + 1] + 0.114f * px[i * 4 + 2]) / 255.0f;
        return v;
    }
};
}  // namespace

// Metal: reduce on the GPU, decide when the command buffer completed
static void sample_screens() {
    static std::atomic<bool> busy{false};
    static Sig drc, tv;
    if (g_mode != kDrcAuto || !R.drc.tex || R.frame % 4 || busy) {
        if (g_mode != kDrcAuto) display_auto_signature({}, nullptr, R.frame);  // forgets the last signature
        return;
    }
    drc.encode(R.drc.tex, R.drc.srgb);
    bool have_tv = R.tv.tex != nil;
    if (have_tv) tv.encode(R.tv.tex, R.tv.srgb);
    busy = true;
    uint64_t frame = R.frame;
    [command_buffer() addCompletedHandler:^(id<MTLCommandBuffer>) {
        std::vector<float> t;
        if (have_tv) t = tv.luma();
        display_auto_signature(drc.luma(), have_tv ? &t : nullptr, frame);
        busy = false;
    }];
}

// ---------------------------------------------------------------- present
static id<MTLTexture> offscreen(NSUInteger w, NSUInteger h, bool srgb) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm
                                                                                 width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    return [R.device newTextureWithDescriptor:d];
}

static void present_to_layer(Screen& scr, void (^draw)(id<MTLTexture>)) {
    if (!scr.layer || !scr.tex) return;
    MTLPixelFormat want = scr.srgb ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
    if (scr.layer.pixelFormat != want) scr.layer.pixelFormat = want;
    // uncapped (gx2::uncapped, debug): presentation does not wait for the display
    const bool sync = !gx2::uncapped() && !gx2::turbo();
#ifndef WWHD_IOS
    if (scr.layer.displaySyncEnabled != sync) {
        scr.layer.displaySyncEnabled = sync;
        if (&scr == &R.tv) interp::set_present_vsync(sync);
    }
#else
    interp::set_present_vsync(sync);
#endif
    id<CAMetalDrawable> drawable = scr.visible ? [scr.layer nextDrawable] : nil;
    if (!drawable) return;
    draw(drawable.texture);
    [command_buffer() presentDrawable:drawable];
}

// Metal, called from swap(): compose and present the TV window (with the GamePad overlay) and the GamePad window
void present_screens() {
    sample_screens();
    CGSize ls = R.tv.layer ? R.tv.layer.drawableSize : CGSizeMake(0, 0);
    PresentPlan P = display_plan(R.tv.tex != nil, R.tv.tex.width, R.tv.tex.height, R.drc.tex != nil, R.drc.tex.width, R.drc.tex.height,
                                 ls.width, ls.height, R.frame);
    update_native_resolution((float)ls.width, (float)ls.height, display_tv_fill_mode() == kTvCrop, P.drc_only);
    Layout L;
    L.tv = P.tv;
    L.pip = P.pip;
    L.pip_on = P.pip_on;
    L.drc_only = P.drc_only;
    L.scale = P.scale;
    float dw = P.dw, dh = P.dh;
    bool pip = P.pip_wanted, drc_only = P.drc_only;
    g_overlay_draw = overlay::frame(dw, dh, overlay_metal_init);  // settings overlay, drawn by compose_tv
    if (P.sim) {
        present_to_layer(R.tv, ^(id<MTLTexture> t) {
            CGSize ds = R.tv.layer.drawableSize;
            Layout simLayout = layout(ds.width, ds.height, R.tv.tex.width, R.tv.tex.height, R.drc.tex ? R.drc.tex.width : 0,
                                      R.drc.tex ? R.drc.tex.height : 0, pip, drc_only);
            compose_tv(t, simLayout, spatial_tv_texture(simLayout));
        });
    } else {
        present_to_layer(R.tv, ^(id<MTLTexture> t) { compose_tv(t, L, spatial_tv_texture(L)); });
    }
    bool drc_win = P.drc_window;
    if (drc_win) present_to_layer(R.drc, ^(id<MTLTexture> t) { compose_drc(t); });

    for (auto& path : display_take_present_dumps()) {
        if (!R.tv.tex || dw < 1 || dh < 1) continue;
        id<MTLTexture> t = offscreen((NSUInteger)dw, (NSUInteger)dh, R.tv.srgb);
        compose_tv(t, L, spatial_tv_texture(L));
        dump_texture(t, path.c_str(), true, false);
        if (drc_win && R.drc.tex && R.drc.layer) {
            CGSize ds = R.drc.layer.drawableSize;
            id<MTLTexture> d = offscreen((NSUInteger)ds.width, (NSUInteger)ds.height, R.drc.srgb);
            compose_drc(d);
            std::string p = path;
            size_t dot = p.rfind(".png");
            p.insert(dot == std::string::npos ? p.size() : dot, "_drc");
            dump_texture(d, p.c_str(), true, false);
        }
        display_log_present_dump(path, P, R.tv.tex.width, R.tv.tex.height);
    }
}

