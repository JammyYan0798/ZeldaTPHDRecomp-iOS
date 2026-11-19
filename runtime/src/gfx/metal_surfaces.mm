#include "mods/cemu_pack.h"
#include <tuple>
#include <atomic>
#include <cmath>
#include <mutex>
#include <vector>
// Guest surfaces <-> Metal textures: render targets, depth buffers, sampled textures.
// Tiled layouts are decoded with the vendored LatteAddrLib.
#include "Cafe/HW/Latte/ISA/LatteReg.h"
#include "Cafe/HW/Latte/ISA/RegDefines.h"
#include "Cafe/HW/Latte/LatteAddrLib/LatteAddrLib.h"
#include "gx2/gx2.h"
#include "render_prof.h"
#include "gx2_texture_regs.h"
#include "../aspect.h"
#include "metal.h"
#include "metal_spatial_upscale.h"
#include "runtime.h"
#include "write_watch.h"
#define XXH_INLINE_ALL
#include "../../third_party/xxhash/xxhash.h"

Latte::E_GX2SURFFMT LatteTexture_ReconstructGX2Format(const Latte::LATTE_SQ_TEX_RESOURCE_WORD1_N&, const Latte::LATTE_SQ_TEX_RESOURCE_WORD4_N&);

namespace gfx {


static MTLTextureType texture_type(uint32_t dim, uint32_t slices) {
    switch ((Latte::E_DIM)dim) {
    case Latte::E_DIM::DIM_1D: return MTLTextureType1D;
    case Latte::E_DIM::DIM_3D: return MTLTextureType3D;
    case Latte::E_DIM::DIM_CUBEMAP: return MTLTextureTypeCube;
    case Latte::E_DIM::DIM_1D_ARRAY: return MTLTextureType1DArray;
    case Latte::E_DIM::DIM_2D_ARRAY: case Latte::E_DIM::DIM_2D_ARRAY_MSAA: return MTLTextureType2DArray;
    default: return slices > 1 ? MTLTextureType2DArray : MTLTextureType2D;
    }
}

uint64_t next_write_seq() {
    static uint64_t seq = 0;
    return ++seq;
}

// ---------------------------------------------------------------- internal resolution
// Render targets are allocated at res_scale() x their guest size. Everything that talks to the game
// (lookups, aliasing, guest memory) uses the guest size; draws scale their viewport and scissor, and
// shaders sample with normalized coordinates, so they see the same picture at more pixels.
static float parse_scale(const char* e) {
    float f = e ? (float)atof(e) : 1.0f;
    // Sub-native values are an explicit render-scale experiment; the default remains 1x.
    return std::clamp(f > 0 ? f : 1.0f, 0.5f, 4.0f);
}
struct CustomResolutionConfig {
    bool active = false;
    bool nativeActive = false;
    bool nativeFailed = false;
    uint32_t width = 0, height = 0;
    uint32_t nativeWidth = 0, nativeHeight = 0;
    double nativeDrawableWidth = 0, nativeDrawableHeight = 0;
    float nativeAspect = 0;
    bool nativeCrop = false, nativeGeometryKnown = false;
    bool failed = false;
    CustomResolutionError error = CustomResolutionError::None;
    float requestedScale = parse_scale(getenv("WWHD_RES_SCALE"));
    float fallbackScale = 1.0f;
    float nativeRestoreScale = 1.0f;
    int restoreAspect = aspect::kOriginal;
    uint64_t generation = 0;
};
static std::mutex g_resolution_mu;
static CustomResolutionConfig g_custom_config;
static std::atomic<float> g_res_frame{g_custom_config.requestedScale};
static bool g_custom_active_frame = false, g_native_active_frame = false, g_custom_failed_frame = false;
static uint32_t g_custom_width_frame = 0, g_custom_height_frame = 0;
static uint32_t g_native_width_frame = 0, g_native_height_frame = 0;
static float g_custom_fallback_frame = 1.0f, g_native_fallback_frame = 1.0f;
static uint64_t g_custom_generation_frame = 0;
static void clear_native_resolution_locked();
static bool g_spatial_native_fallback_requested = false, g_spatial_native_fallback_frame = false;
static float g_aspect_requested = 16.0f / 9.0f;
static void latch_aspect(float a);  // render thread: the factor for this frame
float res_scale() {
    return g_res_frame.load(std::memory_order_relaxed);
}
static void custom_allocation_fallback(const char* reason) {
    if ((!g_custom_active_frame && !g_native_active_frame) || g_custom_failed_frame) return;
    const float fallback = g_custom_active_frame ? g_custom_fallback_frame : g_native_fallback_frame;
    const uint32_t width = g_custom_active_frame ? g_custom_width_frame : g_native_width_frame;
    const uint32_t height = g_custom_active_frame ? g_custom_height_frame : g_native_height_frame;
    {
        std::lock_guard<std::mutex> lock(g_resolution_mu);
        if (g_custom_config.generation == g_custom_generation_frame &&
            ((g_custom_config.active && !g_custom_config.failed) || (g_custom_config.nativeActive && !g_custom_config.nativeFailed))) {
            if (g_custom_active_frame) g_custom_config.failed = true;
            else g_custom_config.nativeFailed = true;
            g_custom_config.error = CustomResolutionError::AllocationFallback;
            g_custom_config.requestedScale = fallback;
        }
        // The current render frame must stop mixing newly allocated fallback targets with old-sized attachments.
        g_custom_failed_frame = true;
        g_res_frame.store(fallback, std::memory_order_relaxed);
    }
    LOG("[gfx] %s internal resolution %ux%u failed (%s); falling back to %.3gx at the same game aspect",
        g_custom_active_frame ? "custom" : "native", width, height, reason, fallback);
}
bool set_custom_resolution(float width, float height) {
    auto reject = [](CustomResolutionError error) {
        std::lock_guard<std::mutex> lock(g_resolution_mu);
        g_custom_config.error = error;
        return false;
    };
    if (!std::isfinite(width) || !std::isfinite(height) || width < 1 || height < 1 || std::floor(width) != width || std::floor(height) != height ||
        width > kCustomResolutionMaxDimension || height > kCustomResolutionMaxDimension) {
        return reject(CustomResolutionError::InvalidDimensions);
    }
    const uint32_t w = (uint32_t)width, h = (uint32_t)height;
    if ((uint64_t)w * h > kCustomResolutionMaxPixels) {
        return reject(CustomResolutionError::PixelLimit);
    }
    const float ratio = float(w) / h, base = 16.0f / 9.0f;
    const float scale = ratio >= base ? float(h) / 1080.0f : float(w) / 1920.0f;
    if (ratio <= kCustomResolutionMinAspect || ratio >= kCustomResolutionMaxAspect || scale < kCustomResolutionMinScale ||
        scale > kCustomResolutionMaxScale) {
        return reject(CustomResolutionError::InvalidDimensions);
    }
    if (!R.device) {
        return reject(CustomResolutionError::DeviceUnavailable);
    }
    MTLTextureDescriptor* probeDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h
                                                                                   mipmapped:NO];
    probeDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    probeDesc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> probe = [R.device newTextureWithDescriptor:probeDesc];
    if (!probe) {
        return reject(CustomResolutionError::TextureProbeFailed);
    }
    probe = nil;
    {
        std::lock_guard<std::mutex> lock(g_resolution_mu);
        clear_native_resolution_locked();
        const bool wasActive = g_custom_config.active;
        const int previousAspect = aspect::set_custom_aspect_mode(ratio);
        if (!wasActive) {
            g_custom_config.fallbackScale = g_custom_config.requestedScale;
            g_custom_config.restoreAspect = previousAspect >= 0 ? previousAspect : aspect::kOriginal;
        }
        g_custom_config.active = true;
        g_custom_config.failed = false;
        g_custom_config.error = CustomResolutionError::None;
        g_custom_config.width = w;
        g_custom_config.height = h;
        g_custom_config.requestedScale = scale;
        ++g_custom_config.generation;
    }
    LOG("[gfx] custom internal resolution %ux%u (%.3gx, aspect %.4f)", w, h, scale, ratio);
    return true;
}
static void clear_custom_resolution_locked() {
    if (!g_custom_config.active) {
        g_custom_config.error = CustomResolutionError::None;
        return;
    }
    g_custom_config.active = false;
    g_custom_config.failed = false;
    g_custom_config.error = CustomResolutionError::None;
    g_custom_config.width = 0;
    g_custom_config.height = 0;
    g_custom_config.requestedScale = g_custom_config.fallbackScale;
    if (aspect::mode() == aspect::kCustom) {
        aspect::set_mode(g_custom_config.restoreAspect);
    }
    ++g_custom_config.generation;
}
static void clear_native_resolution_locked() {
    if (!g_custom_config.nativeActive) return;
    g_custom_config.nativeActive = false;
    g_custom_config.nativeFailed = false;
    g_custom_config.requestedScale = g_custom_config.nativeRestoreScale;
    g_custom_config.nativeWidth = g_custom_config.nativeHeight = 0;
    g_custom_config.nativeGeometryKnown = false;
    g_custom_config.error = CustomResolutionError::None;
    ++g_custom_config.generation;
}
void clear_custom_resolution() {
    std::lock_guard<std::mutex> lock(g_resolution_mu);
    clear_native_resolution_locked();
    clear_custom_resolution_locked();
}
CustomResolutionStatus custom_resolution_status() {
    CustomResolutionStatus s;
    float scale, a;
    {
        std::lock_guard<std::mutex> lock(g_resolution_mu);
        s.active = g_custom_config.active;
        s.nativeActive = g_custom_config.nativeActive;
        s.requestedWidth = s.nativeActive ? g_custom_config.nativeWidth : g_custom_config.width;
        s.requestedHeight = s.nativeActive ? g_custom_config.nativeHeight : g_custom_config.height;
        s.error = g_custom_config.error;
        const bool spatial_fallback = g_custom_config.requestedScale < 1.0f && g_spatial_native_fallback_requested && spatial_upscale_failed();
        if (s.nativeActive && g_custom_config.error == CustomResolutionError::None && !spatial_fallback &&
            g_custom_config.nativeWidth && g_custom_config.nativeHeight) {
            s.effectiveWidth = g_custom_config.nativeWidth;
            s.effectiveHeight = g_custom_config.nativeHeight;
            return s;
        }
        scale = g_custom_config.active && !g_custom_config.failed ? g_custom_config.requestedScale
                                                                  : g_custom_config.failed ? g_custom_config.fallbackScale
                                                                                           : g_res_frame.load(std::memory_order_relaxed);
        a = aspect::requested();
        if (scale < 1.0f && g_spatial_native_fallback_requested && spatial_upscale_failed()) scale = 1.0f;
    }
    const float base = 16.0f / 9.0f;
    const float kx = a >= base ? a / base : 1.0f, ky = a >= base ? 1.0f : base / a;
    s.effectiveWidth = (uint32_t)std::lround(1920.0f * scale * kx);
    s.effectiveHeight = (uint32_t)std::lround(1080.0f * scale * ky);
    return s;
}
bool custom_resolution_fallback_frame() { return (g_custom_active_frame || g_native_active_frame) && g_custom_failed_frame; }
void set_native_resolution_enabled(bool enabled) {
    std::lock_guard<std::mutex> lock(g_resolution_mu);
    if (enabled) {
        if (g_custom_config.nativeActive) return;
        clear_custom_resolution_locked();
        g_custom_config.nativeRestoreScale = g_custom_config.requestedScale;
        g_custom_config.nativeActive = true;
        g_custom_config.nativeFailed = false;
        g_custom_config.nativeWidth = g_custom_config.nativeHeight = 0;
        g_custom_config.nativeGeometryKnown = false;
        g_custom_config.error = CustomResolutionError::None;
        ++g_custom_config.generation;
    } else {
        clear_native_resolution_locked();
    }
}
void update_native_resolution(float drawable_width, float drawable_height, bool crop, bool drc_only) {
    if (drc_only) return;  // GamePad-only holds the last TV scale until TV presentation resumes.
    const float applied_aspect = aspect::game();
    std::lock_guard<std::mutex> lock(g_resolution_mu);
    if (!g_custom_config.nativeActive) return;
    if (g_custom_config.nativeGeometryKnown && g_custom_config.nativeDrawableWidth == drawable_width &&
        g_custom_config.nativeDrawableHeight == drawable_height && std::fabs(g_custom_config.nativeAspect - applied_aspect) < 0.0001f &&
        g_custom_config.nativeCrop == crop)
        return;
    g_custom_config.nativeGeometryKnown = true;
    g_custom_config.nativeDrawableWidth = drawable_width;
    g_custom_config.nativeDrawableHeight = drawable_height;
    g_custom_config.nativeAspect = applied_aspect;
    g_custom_config.nativeCrop = crop;

    const native_resolution::Geometry geometry = native_resolution::fit_crop(drawable_width, drawable_height, applied_aspect, crop);
    if (!geometry) {
        switch (geometry.error) {
        case native_resolution::Error::DimensionLimit: g_custom_config.error = CustomResolutionError::DimensionLimit; break;
        case native_resolution::Error::PixelLimit: g_custom_config.error = CustomResolutionError::PixelLimit; break;
        default: g_custom_config.error = CustomResolutionError::InvalidDimensions; break;
        }
        return;  // Keep the previous scale and dimensions.
    }
    g_custom_config.nativeFailed = false;
    g_custom_config.error = CustomResolutionError::None;
    g_custom_config.nativeWidth = geometry.width;
    g_custom_config.nativeHeight = geometry.height;
    if (std::fabs(g_custom_config.requestedScale - geometry.scale) > 0.0001f) {
        g_custom_config.requestedScale = geometry.scale;
        ++g_custom_config.generation;
    }
}
void request_spatial_upscale_native_fallback() {
    if (!spatial_upscale_failed()) return;
    std::lock_guard<std::mutex> lock(g_resolution_mu);
    g_spatial_native_fallback_requested = true;
}
const char* custom_resolution_error_name(CustomResolutionError error) {
    switch (error) {
    case CustomResolutionError::None: return "none";
    case CustomResolutionError::InvalidDimensions: return "dimensions must be finite whole pixels with a supported aspect and scale";
    case CustomResolutionError::PixelLimit: return "pixel count exceeds the internal resolution limit";
    case CustomResolutionError::DeviceUnavailable: return "Metal device is not ready";
    case CustomResolutionError::TextureProbeFailed: return "the device could not allocate a texture at this size";
    case CustomResolutionError::AllocationFallback: return "a render target allocation failed; using the previous scale";
    case CustomResolutionError::DimensionLimit: return "dimensions exceed the internal resolution limit";
    }
    return "unknown resolution error";
}
void set_res_scale(float f) {
    const float scale = std::clamp(f, 0.5f, 4.0f);
    {
        std::lock_guard<std::mutex> lock(g_resolution_mu);
        clear_native_resolution_locked();
        clear_custom_resolution_locked();
        g_custom_config.failed = false;
        g_custom_config.error = CustomResolutionError::None;
        g_custom_config.requestedScale = scale;
        ++g_custom_config.generation;
    }
    LOG("[gfx] internal resolution %gx", scale);
}
void latch_res_scale() {
    // test aid: WWHD_RES_SCALE_AT=frame:factor,... switches the factor at those frames
    static std::vector<std::pair<uint64_t, float>> at = [] {
        std::vector<std::pair<uint64_t, float>> v;
        if (const char* e = getenv("WWHD_RES_SCALE_AT"))
            for (char* p = (char*)e; *p;) {
                uint64_t f = strtoull(p, &p, 10);
                if (*p++ != ':') break;
                v.push_back({f, (float)strtod(p, &p)});
                while (*p == ',') p++;
            }
        return v;
    }();
    for (auto& [f, v] : at)
        if (R.frame == f) set_res_scale(v);
    {
        std::lock_guard<std::mutex> lock(g_resolution_mu);
        // aspect::service applies the requested game aspect before its swap. Hold the prior frame
        // snapshot until that render-thread aspect arrives, so dimensions and aspect change together.
        const float gameAspect = aspect::game();
        const bool gameAspectCurrent = std::fabs(gameAspect - aspect::requested()) <= 0.005f;
        const bool rendererAspectCurrent = std::fabs(g_aspect_requested - gameAspect) <= 0.0001f;
        if (gameAspectCurrent && rendererAspectCurrent) {
            g_custom_active_frame = g_custom_config.active;
            g_native_active_frame = g_custom_config.nativeActive;
            g_custom_failed_frame = g_custom_config.failed || g_custom_config.nativeFailed;
            g_custom_width_frame = g_custom_config.width;
            g_custom_height_frame = g_custom_config.height;
            g_native_width_frame = g_custom_config.nativeWidth;
            g_native_height_frame = g_custom_config.nativeHeight;
            g_custom_fallback_frame = g_custom_config.fallbackScale;
            g_native_fallback_frame = g_custom_config.nativeRestoreScale;
            g_custom_generation_frame = g_custom_config.generation;
            float frameScale = g_custom_config.failed ? g_custom_config.fallbackScale :
                               g_custom_config.nativeFailed ? g_custom_config.nativeRestoreScale : g_custom_config.requestedScale;
            if (!spatial_upscale_failed()) g_spatial_native_fallback_requested = false;
            g_spatial_native_fallback_frame = g_spatial_native_fallback_requested && spatial_upscale_failed();
            if (g_spatial_native_fallback_frame && frameScale < 1.0f) frameScale = 1.0f;
            g_res_frame.store(frameScale, std::memory_order_relaxed);
            latch_aspect(g_aspect_requested);
        }
    }
}

// ---------------------------------------------------------------- aspect ratio
// The game renders a 16:9 screen (1280x720 guest pixels). At another aspect ratio (aspect.cpp) the
// game's projections are widened (or made taller) and every screen-shaped render target is allocated
// that much wider (taller) than its guest size: draws keep their guest viewports, which cover the
// whole texture, so the picture comes out at the new shape without the game knowing. kx/ky: texture
// pixels per guest pixel on top of the internal resolution, (A / (16/9), 1) for wider screens,
// (1, (16/9) / A) for narrower ones. Latched at the frame boundary like the resolution.
static float g_aspect_kx = 1.0f, g_aspect_ky = 1.0f;  // render thread: factors for this frame
void set_frame_aspect(float a) {
    std::lock_guard<std::mutex> lock(g_resolution_mu);
    g_aspect_requested = a;
}
static void latch_aspect(float a) {
    const float base = 16.0f / 9.0f;
    float kx = a >= base ? a / base : 1.0f, ky = a >= base ? 1.0f : base / a;
    if (kx != g_aspect_kx || ky != g_aspect_ky) LOG("[gfx] aspect %.4f: screen targets x%.4f wide, x%.4f tall", a, kx, ky);
    g_aspect_kx = kx;
    g_aspect_ky = ky;
}
// the game's screen-sized buffers and their reductions (1920x1080 ... 60x33); not the GamePad's
// (854x480, shown in its own window), not shadow maps, mip chains or textures
static bool screen_shaped(const Surface* s) {
    if (s->fmt.compressed || s->mips > 1 || s->slices > 1 || s->width < 32) return false;
    for (uint32_t w = 854, h = 480; w >= 32; w >>= 1, h >>= 1)
        if ((s->width == w || s->width == w + 1) && s->height == h) return false;
    float r = (float)s->width * 9.0f / ((float)s->height * 16.0f);
    return r > 0.97f && r < 1.03f;
}

// the factor a render target gets. Shadow maps (depth arrays: the game's cascades) scale with the
// internal resolution by default (sharper shadows; the user's choice). WWHD_SHADOW_FIX=1 keeps the
// console's 1024x1024 (issue #67), and WWHD_SHADOW_SCALE=n gives them their own factor (overrides
// both). The trade-off: the game softens shadow edges by sampling the map with bilinear depth compare at a per-pixel random
// offset, then blurring the result on screen. At 2048x2048 each compare filters half as wide, so
// shadow edges came out hard and the random offsets showed as crawling hatching (issue #67: the
// bridge's shadow on Outset's water, hard and shimmering at 2x). Cemu's graphics packs also keep
// the shadow maps at the console's size unless asked.
static float target_scale(const Surface* s) {
    uint32_t width,height;
    if(!s->fmt.compressed&&s->mips==1&&mods::cemu::texture_extent(s->width,s->height,s->format,s->slices,s->tileMode,width,height))return 1.0f;
    if (s->fmt.compressed || s->mips > 1) return 1.0f;
    static const float shadow = getenv("WWHD_SHADOW_SCALE") ? std::max(1.0f, parse_scale(getenv("WWHD_SHADOW_SCALE")))
                                : getenv("WWHD_SHADOW_FIX") && *getenv("WWHD_SHADOW_FIX") && *getenv("WWHD_SHADOW_FIX") != '0' ? 1.0f : 0.0f;
    if (shadow && s->isDepth && s->slices > 1) return shadow;
    // The frame latch applies the explicit MetalFX-failure fallback without changing the user's request.
    return res_scale();
}
// extra horizontal / vertical factor for the aspect ratio
static void target_aspect(const Surface* s, float& kx, float& ky) {
    uint32_t width,height;
    if(!s->fmt.compressed&&s->mips==1&&mods::cemu::texture_extent(s->width,s->height,s->format,s->slices,s->tileMode,width,height)){
        kx=float(width)/s->width;ky=float(height)/s->height;return;
    }
    bool on = screen_shaped(s);
    kx = on ? g_aspect_kx : 1.0f;
    ky = on ? g_aspect_ky : 1.0f;
}

static id<MTLTexture> make_texture(Surface* s, MTLTextureType type, bool forRendering, float scale, float ax = 1.0f, float ay = 1.0f) {
    // render targets: 2D, 2D arrays and volumes (rendered slice by slice: the game's colour-grading volumes)
    if (forRendering && type != MTLTextureType2DArray && type != MTLTextureType3D) type = MTLTextureType2D;
    bool is1D = type == MTLTextureType1D || type == MTLTextureType1DArray;
    uint32_t pw = s->width, ph = s->height;
    auto sized = [&] {
        pw = s->width;
        ph = s->height;
        if ((scale != 1.0f || ax != 1.0f || ay != 1.0f) && !is1D && type != MTLTextureType3D) {
            pw = (uint32_t)std::ceil(s->width * scale * ax - 0.01f);
            ph = (uint32_t)std::ceil(s->height * scale * ay - 0.01f);
        } else {
            scale = 1.0f;
            ax = ay = 1.0f;
        }
    };
    // volumes keep the guest size (they are sampled as lookup tables, not shown)
    sized();
    MTLTextureDescriptor* td = [MTLTextureDescriptor new];
    td.textureType = type;
    td.pixelFormat = s->fmt.pixel;
    td.width = pw;
    td.height = is1D ? 1 : ph;
    td.depth = type == MTLTextureType3D ? s->slices : 1;
    td.arrayLength = (type == MTLTextureType2DArray || type == MTLTextureType1DArray) ? s->slices : 1;
    if (type == MTLTextureTypeCube) td.arrayLength = 1;
    td.mipmapLevelCount = s->mips;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
    td.storageMode = MTLStorageModePrivate;
    if (s->fmt.compressed) td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> t = [R.device newTextureWithDescriptor:td];
    if (!t && (g_custom_active_frame || g_native_active_frame) && !g_custom_failed_frame) {
        custom_allocation_fallback("Metal texture allocation");
        scale = g_custom_active_frame ? g_custom_fallback_frame : g_native_fallback_frame;
        sized();
        td.width = pw;
        td.height = is1D ? 1 : ph;
        t = [R.device newTextureWithDescriptor:td];
    }
    if (t) {
        s->scale = scale;
        s->ax = ax;
        s->ay = ay;
        s->sx = (float)pw / s->width;
        s->sy = is1D ? 1.0f : (float)ph / s->height;
    }
    return t;
}

// a render target made at another factor (the setting changed, or a CPU texture now rendered to):
// reallocate it at the current one, keeping its contents (filtered)
static Surface* rescale(Surface* s) {
    float want = target_scale(s), ax, ay;
    target_aspect(s, ax, ay);
    if ((s->scale == want && s->ax == ax && s->ay == ay) || !s->tex || s->tex.textureType == MTLTextureType3D) return s;
    id<MTLTexture> old = s->tex;
    float osx = s->sx, osy = s->sy, oscale = s->scale, oax = s->ax, oay = s->ay;
    id<MTLTexture> t = make_texture(s, old.textureType, true, want, ax, ay);
    if (!t) { s->sx = osx; s->sy = osy; s->scale = oscale; s->ax = oax; s->ay = oay; return s; }
    end_encoder();
    resample(old, t, s->fmt, old.textureType == MTLTextureType2DArray ? (uint32_t)old.arrayLength : 1);
    s->tex = t;
    forget_texture_views();
    if (getenv("WWHD_LOG_RESCALE"))
        LOG("[gfx] rescaled %08X %ux%u fmt %X to %lux%lu", s->addr, s->width, s->height, s->format, (unsigned long)t.width,
            (unsigned long)t.height);
    return s;
}

// fullscreen-triangle copy with filtering; one pipeline per destination format
static const char* kResampleShader = R"(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut rs_vs(uint vid [[vertex_id]], constant float2& uvMax [[buffer(0)]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
    o.uv = p * uvMax;
    return o;
}
fragment float4 rs_float(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, in.uv);
}
fragment uint4 rs_uint(VOut in [[stage_in]], texture2d<uint> t [[texture(0)]]) {
    return t.read(uint2(min(in.uv * float2(t.get_width(), t.get_height()), float2(t.get_width() - 1, t.get_height() - 1))));
}
fragment int4 rs_sint(VOut in [[stage_in]], texture2d<int> t [[texture(0)]]) {
    return t.read(uint2(min(in.uv * float2(t.get_width(), t.get_height()), float2(t.get_width() - 1, t.get_height() - 1))));
}
struct DOut { float d [[depth(any)]]; };
fragment DOut rs_depth(VOut in [[stage_in]], depth2d<float> t [[texture(0)]]) {
    DOut o;
    o.d = t.read(uint2(min(in.uv * float2(t.get_width(), t.get_height()), float2(t.get_width() - 1, t.get_height() - 1))));
    return o;
}
)";

void resample(id<MTLTexture> src, id<MTLTexture> dst, const FormatInfo& fmt, uint32_t slices, float uMax, float vMax, uint32_t dstW,
              uint32_t dstH) {
    static id<MTLLibrary> lib;
    static id<MTLSamplerState> linear;
    static std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pipes;
    if (!lib) {
        NSError* err = nil;
        lib = [R.device newLibraryWithSource:[NSString stringWithUTF8String:kResampleShader] options:nil error:&err];
        if (!lib) { LOG("[gfx] resample shader: %s", err.localizedDescription.UTF8String); return; }
        MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        linear = [R.device newSamplerStateWithDescriptor:sd];
    }
    if (fmt.compressed) return;
    uint64_t key = (uint64_t)dst.pixelFormat;
    auto it = pipes.find(key);
    if (it == pipes.end()) {
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"rs_vs"];
        NSString* fs = fmt.depth ? @"rs_depth" : fmt.kind == FormatInfo::UINT ? @"rs_uint" : fmt.kind == FormatInfo::SINT ? @"rs_sint" : @"rs_float";
        d.fragmentFunction = [lib newFunctionWithName:fs];
        if (fmt.depth) {
            d.depthAttachmentPixelFormat = dst.pixelFormat;
            if (fmt.stencil) d.stencilAttachmentPixelFormat = dst.pixelFormat;
        } else {
            d.colorAttachments[0].pixelFormat = dst.pixelFormat;
        }
        NSError* err = nil;
        id<MTLRenderPipelineState> p = [R.device newRenderPipelineStateWithDescriptor:d error:&err];
        if (!p) LOG("[gfx] resample pipeline (pixel %lu): %s", (unsigned long)dst.pixelFormat, err.localizedDescription.UTF8String);
        it = pipes.emplace(key, p).first;
    }
    if (!it->second) return;
    static id<MTLDepthStencilState> writeDepth;
    if (!writeDepth) {
        MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = YES;
        writeDepth = [R.device newDepthStencilStateWithDescriptor:dd];
    }
    end_encoder();
    for (uint32_t z = 0; z < slices; z++) {
        id<MTLTexture> view = [src newTextureViewWithPixelFormat:src.pixelFormat textureType:MTLTextureType2D
                                                          levels:NSMakeRange(0, 1) slices:NSMakeRange(z, 1)];
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        bool whole = !dstW || (dstW >= dst.width && dstH >= dst.height);
        if (fmt.depth) {
            rp.depthAttachment.texture = dst;
            rp.depthAttachment.slice = z;
            rp.depthAttachment.loadAction = whole ? MTLLoadActionDontCare : MTLLoadActionLoad;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            if (fmt.stencil) {
                rp.stencilAttachment.texture = dst;
                rp.stencilAttachment.slice = z;
                rp.stencilAttachment.loadAction = whole ? MTLLoadActionClear : MTLLoadActionLoad;
                rp.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        } else {
            rp.colorAttachments[0].texture = dst;
            rp.colorAttachments[0].slice = z;
            rp.colorAttachments[0].loadAction = whole ? MTLLoadActionDontCare : MTLLoadActionLoad;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        }
        id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:it->second];
        if (fmt.depth) [e setDepthStencilState:writeDepth];
        if (dstW) [e setViewport:MTLViewport{0, 0, (double)dstW, (double)dstH, 0, 1}];
        float uv[2] = {uMax, vMax};
        [e setVertexBytes:uv length:sizeof uv atIndex:0];
        [e setFragmentTexture:view atIndex:0];
        [e setFragmentSamplerState:linear atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    }
}

// One guest surface can be rendered and sampled through views of different formats with the same
// texel bits, e.g. RGBA8 and RGBA8 sRGB: the Picto Box draws its picture through the sRGB view and
// then through the plain one (issue #53). Each format gets its own texture here, so before one is
// used, take over the texels of a more recent compatible one (a raw copy, as the memory is shared).
static Surface* adopt_newer_alias(Surface* s) {
    if (!s || !s->formatViews || !s->tex) return s;  // the common case: one view per address, nothing to do
    if (R.binding) return s;  // a texture looked up again while binding to the open encoder: no blits now
    Surface* newest = nullptr;
    auto range = R.surfaces.equal_range(s->addr);
    for (auto it = range.first; it != range.second; ++it) {
        Surface* o = it->second.get();
        if (o == s || !o->gpuWritten || !o->tex || o->isDepth || o->fmt.compressed || o->fmt.convert != Convert::NONE) continue;
        if (s->gpuWritten && o->writeSeq <= s->writeSeq) continue;
        if ((o->format & 0x3F) != (s->format & 0x3F) || o->fmt.hostBytesPerBlock != s->fmt.hostBytesPerBlock) continue;
        if (o->tex.textureType != s->tex.textureType || o->tex.width != s->tex.width || o->tex.height != s->tex.height ||
            o->tex.depth != s->tex.depth || o->tex.arrayLength != s->tex.arrayLength)
            continue;
        if (!newest || o->writeSeq > newest->writeSeq) newest = o;
    }
    if (!newest) return s;
    id<MTLTexture> src = newest->tex.pixelFormat == s->tex.pixelFormat ? newest->tex : [newest->tex newTextureViewWithPixelFormat:s->tex.pixelFormat];
    if (!src) return s;
    end_encoder();
    id<MTLBlitCommandEncoder> b = [command_buffer() blitCommandEncoder];
    NSUInteger layers = s->tex.textureType == MTLTextureType3D ? 1 : std::max<NSUInteger>(s->tex.arrayLength, 1);
    if (s->tex.textureType == MTLTextureTypeCube) layers = 6;
    for (NSUInteger level = 0; level < std::min(s->tex.mipmapLevelCount, newest->tex.mipmapLevelCount); level++)
        for (NSUInteger slice = 0; slice < layers; slice++)
            [b copyFromTexture:src sourceSlice:slice sourceLevel:level sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(std::max<NSUInteger>(s->tex.width >> level, 1), std::max<NSUInteger>(s->tex.height >> level, 1),
                                           std::max<NSUInteger>(s->tex.depth >> level, 1))
                     toTexture:s->tex destinationSlice:slice destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
    [b endEncoding];
    mark_gpu_written(s);
    return s;
}

// the existing surface a lookup resolves to, or nullptr
static Surface* find_surface(const SurfaceDesc& d, bool forRendering) {
    auto range = R.surfaces.equal_range(d.addr);
    Surface* exact = nullptr;
    // sampling a GPU-written surface: several can alias one address (mip chains rendered into the same
    // memory, a render target recreated as a texture array...). Prefer the same size, then the same
    // array size, then the most recent write.
    Surface* rendered = nullptr;
    auto score = [&](Surface* s) {
        return std::make_tuple(s->width == d.width && s->height == d.height, s->slices == d.slices, s->writeSeq);
    };
    // only with the same kind of texture: a 2D render target cannot stand in for a sampled volume
    auto volume = [](uint32_t dim) { return (Latte::E_DIM)dim == Latte::E_DIM::DIM_3D; };
    auto consider = [&](Surface* s) {
        if (volume(s->dim) != volume(d.dim)) return;
        if (!rendered || score(s) > score(rendered)) rendered = s;
    };
    for (auto it = range.first; it != range.second; ++it) {
        Surface* s = it->second.get();
        // a rendered depth buffer sampled as a texture (fog, depth of field, shadow maps...)
        if (!forRendering && s->isDepth && !d.isDepth && s->gpuWritten && s->width == d.width && s->height == d.height)
            consider(s);
        if (s->isDepth != d.isDepth) continue;
        // a render target is one level. A texture made first by sampling the address (with the mip
        // chain its descriptor declares) is not adopted as a target: rendering would define level
        // 0 only, and samplers would keep reading the other levels as uploaded from guest memory,
        // for the rest of the session. That happens when a pass samples a buffer before the pass
        // that renders it has run once, e.g. its draw was skipped while its shader compiled (issue
        // #47: the light buffer, black shadows). The target gets its own surface instead, which
        // then wins sampling lookups as the newest write, as when the render came first.
        if (forRendering && s->mips > 1) continue;
        // a volume and a 2D array of the same size are different textures
        if (s->width == d.width && s->height == d.height && s->format == d.format && s->slices == d.slices &&
            volume(s->dim) == volume(d.dim) && (forRendering || s->mips >= d.mips || s->gpuWritten)) {
            if (forRendering) return adopt_newer_alias(rescale(s));
            if (!exact || s->writeSeq > exact->writeSeq) exact = s;
            continue;
        }
        // render target being sampled with a compatible format but different view parameters
        if (!forRendering && s->gpuWritten && (s->format & 0x3F) == (d.format & 0x3F)) consider(s);
    }
    if (exact && (exact->gpuWritten || !rendered || exact->writeSeq > rendered->writeSeq)) return exact->gpuWritten ? adopt_newer_alias(exact) : exact;
    if (rendered) return rendered;
    return exact;
}

Surface* find_or_create_surface(const SurfaceDesc& d, bool forRendering) {
    if (Surface* found = find_surface(d, forRendering)) return found;
    auto s = std::make_unique<Surface>();
    s->addr = d.addr;
    s->mipAddr = d.mipAddr;
    s->width = std::max(d.width, 1u);
    s->height = std::max(d.height, 1u);
    s->slices = std::max(d.slices, 1u);
    s->pitch = d.pitch;
    s->mips = forRendering ? 1 : std::max(d.mips, 1u);
    s->format = d.format;
    s->dim = d.dim;
    s->tileMode = d.tileMode;
    s->swizzle = d.swizzle;
    s->isDepth = d.isDepth;
    s->fmt = format_info(d.format, d.isDepth);
    float ax = 1.0f, ay = 1.0f;
    if (forRendering) target_aspect(s.get(), ax, ay);
    s->tex = make_texture(s.get(), texture_type(d.dim, s->slices), forRendering, forRendering ? target_scale(s.get()) : 1.0f, ax, ay);
    if (!s->tex) {
        LOG("[gfx] cannot create %ux%ux%u texture (format %X, pixel %lu)", s->width, s->height, s->slices, s->format,
            (unsigned long)s->fmt.pixel);
        return nullptr;
    }
    if (forRendering && getenv("WWHD_LOG_RESCALE"))
        LOG("[gfx] render target %08X %ux%ux%u fmt %X%s -> %lux%lu", s->addr, s->width, s->height, s->slices, s->format,
            s->isDepth ? " depth" : "", (unsigned long)s->tex.width, (unsigned long)s->tex.height);
    Surface* raw = s.get();
    R.surfaces.emplace(d.addr, std::move(s));
    // format views of one guest surface (adopt_newer_alias): flag them once, so lookups stay cheap
    if (!raw->isDepth && !raw->fmt.compressed && raw->fmt.convert == Convert::NONE) {
        auto views = R.surfaces.equal_range(d.addr);
        for (auto it = views.first; it != views.second; ++it) {
            Surface* o = it->second.get();
            if (o != raw && !o->isDepth && !o->fmt.compressed && o->fmt.convert == Convert::NONE && o->format != raw->format &&
                (o->format & 0x3F) == (raw->format & 0x3F) && o->fmt.hostBytesPerBlock == raw->fmt.hostBytesPerBlock)
                o->formatViews = raw->formatViews = true;
        }
    }
    if (!raw->isDepth && (Latte::E_HWTILEMODE)raw->tileMode == Latte::E_HWTILEMODE::TM_LINEAR_ALIGNED) R.linearTargets.push_back(raw);
    return forRendering ? adopt_newer_alias(raw) : raw;
}

// ---------------------------------------------------------------- render targets
// CB_COLORn_BASE holds the full guest address; CB_COLORn_TILE/FRAG hold width/height (our convention).
constexpr uint32_t kDim2D = 1, kDim3D = 2, kDim2DArray = 5;

Surface* color_target(const uint32_t* regs, int i, uint32_t* slice) {
    uint32_t base = regs[mmCB_COLOR0_BASE + i];
    if (!base) return nullptr;
    uint32_t size = regs[mmCB_COLOR0_SIZE + i], info = regs[mmCB_COLOR0_INFO + i];
    uint32_t pitch = ((size & 0x3FF) + 1) * 8;
    uint32_t height = (((size >> 10) & 0xFFFFF) + 1) * 64 / pitch;
    // our convention (GX2SetColorBuffer, gx2.h kColorTarget3D): TILE = width | slices << 16 | volume flag, FRAG = height
    uint32_t tile = regs[mmCB_COLOR0_TILE + i];
    uint32_t w = tile & 0xFFFF, h = regs[mmCB_COLOR0_FRAG + i];
    uint32_t slices = gx2::color_target_slices(tile);
    bool volume = (tile & gx2::kColorTarget3D) != 0;
    if (slice) *slice = slices > 1 ? std::min<uint32_t>(regs[mmCB_COLOR0_VIEW + i] & 0x7FF, slices - 1) : 0;
    static const uint32_t numberBits[8] = {0, 0x200, 0, 0, 0x100, 0x300, 0x400, 0x800};
    SurfaceDesc d;
    d.addr = base;
    d.width = w ? w : pitch;
    d.height = h ? h : height;
    d.pitch = pitch;
    d.format = ((info >> 2) & 0x3F) | numberBits[(info >> 12) & 7];
    d.tileMode = (info >> 8) & 0xF;
    d.slices = slices;
    d.dim = volume ? kDim3D : slices > 1 ? kDim2DArray : kDim2D;
    return find_or_create_surface(d, true);
}

Surface* depth_target(const uint32_t* regs, uint32_t* slice) {
    uint32_t base = regs[mmDB_DEPTH_BASE];
    if (!base) return nullptr;
    uint32_t slices = std::max<uint32_t>(regs[gx2::kDepthSlicesReg], 1);
    if (slice) *slice = slices > 1 ? std::min<uint32_t>(regs[mmDB_DEPTH_VIEW] & 0x7FF, slices - 1) : 0;
    uint32_t size = regs[mmDB_DEPTH_SIZE], info = regs[mmDB_DEPTH_INFO];
    uint32_t pitch = ((size & 0x3FF) + 1) * 8;
    uint32_t height = (((size >> 10) & 0xFFFFF) + 1) * 64 / pitch;
    uint32_t wh = regs[mmDB_HTILE_DATA_BASE];  // our convention: width << 16 | height
    static const uint32_t fmts[8] = {0, 0x005, 0, 0x011, 0, 0x811, 0x80E, 0x81C};
    SurfaceDesc d;
    d.addr = base;
    d.width = wh ? (wh >> 16) : pitch;
    d.height = wh ? (wh & 0xFFFF) : height;
    d.pitch = pitch;
    d.format = fmts[info & 7];
    d.isDepth = true;
    d.slices = slices;
    d.dim = slices > 1 ? kDim2DArray : kDim2D;
    return find_or_create_surface(d, true);
}

Surface* surface_from_color_buffer(uint32_t addr, uint32_t* firstSlice, uint32_t* numSlices) {
    auto* cb = (GX2::GX2ColorBuffer*)mem::ptr(addr);
    SurfaceDesc d;
    bool volume = cb->surface.dim.value() == Latte::E_DIM::DIM_3D;
    uint32_t slices = cb->surface.dim.value() == Latte::E_DIM::DIM_2D_ARRAY ? std::max<uint32_t>(cb->surface.depth, 1)
                      : volume ? std::max<uint32_t>(cb->surface.depth >> cb->viewMip, 1) : 1;
    d.slices = slices;
    d.dim = volume ? kDim3D : slices > 1 ? kDim2DArray : kDim2D;
    if (firstSlice) *firstSlice = std::min<uint32_t>(cb->viewFirstSlice, slices - 1);
    if (numSlices) *numSlices = std::clamp<uint32_t>(cb->viewNumSlices, 1, slices - std::min<uint32_t>(cb->viewFirstSlice, slices - 1));
    d.addr = gx2::color_buffer_address(cb);
    d.width = std::max<uint32_t>(cb->surface.width >> cb->viewMip, 1);
    d.height = std::max<uint32_t>(cb->surface.height >> cb->viewMip, 1);
    d.pitch = cb->surface.pitch;
    d.format = (uint32_t)cb->surface.format.value();
    d.tileMode = (uint32_t)cb->surface.tileMode.value();
    return find_or_create_surface(d, true);
}

Surface* surface_from_depth_buffer(uint32_t addr, uint32_t* firstSlice, uint32_t* numSlices) {
    auto* db = (GX2::GX2DepthBuffer*)mem::ptr(addr);
    SurfaceDesc d;
    uint32_t slices = db->surface.dim.value() == Latte::E_DIM::DIM_2D_ARRAY ? std::max<uint32_t>(db->surface.depth, 1) : 1;
    d.slices = slices;
    d.dim = slices > 1 ? kDim2DArray : kDim2D;
    if (firstSlice) *firstSlice = std::min<uint32_t>(db->viewFirstSlice, slices - 1);
    if (numSlices) *numSlices = std::clamp<uint32_t>(db->viewNumSlices, 1, slices - std::min<uint32_t>(db->viewFirstSlice, slices - 1));
    d.addr = db->surface.imagePtr;
    d.width = db->surface.width;
    d.height = db->surface.height;
    d.pitch = db->surface.pitch;
    d.format = (uint32_t)db->surface.format.value();
    d.tileMode = (uint32_t)db->surface.tileMode.value();
    d.isDepth = true;
    return find_or_create_surface(d, true);
}

// ---------------------------------------------------------------- sampled textures
static uint64_t sparse_hash(Surface* s);
static void check_texture(Surface* s);
uint64_t g_stat_full_checks, g_stat_uploads, g_stat_invalidates, g_stat_invalidated_surfaces;

Surface* sampled_texture(const uint32_t* w, bool isDepthSampler) {
    Latte::LATTE_SQ_TEX_RESOURCE_WORD0_N w0;
    Latte::LATTE_SQ_TEX_RESOURCE_WORD1_N w1;
    Latte::LATTE_SQ_TEX_RESOURCE_WORD4_N w4;
    Latte::LATTE_SQ_TEX_RESOURCE_WORD5_N w5;
    memcpy(&w0, &w[0], 4);
    memcpy(&w1, &w[1], 4);
    memcpy(&w4, &w[4], 4);
    memcpy(&w5, &w[5], 4);
    uint32_t addr = w[2] << 8, mipAddr = w[3] << 8;
    if (!addr) return nullptr;
    auto dim = w0.get_DIM();
    uint32_t pitch = (w0.get_PITCH() + 1) << 3;
    uint32_t width = w0.get_WIDTH() + 1;
    uint32_t height = w1.get_HEIGHT() + 1;
    uint32_t depth = w1.get_DEPTH();
    if (dim == Latte::E_DIM::DIM_2D_ARRAY || dim == Latte::E_DIM::DIM_3D || dim == Latte::E_DIM::DIM_2D_ARRAY_MSAA ||
        dim == Latte::E_DIM::DIM_1D_ARRAY)
        depth += 1;
    else {
        if (dim == Latte::E_DIM::DIM_CUBEMAP) depth = 6 * (depth + 1);
        if (depth == 0) depth = 1;
    }
    if (dim == Latte::E_DIM::DIM_1D || dim == Latte::E_DIM::DIM_1D_ARRAY) height = 1;
    auto tileMode = w0.get_TILE_MODE();
    if (Latte::IsCompressedFormat(w1.get_DATA_FORMAT())) pitch /= 4;
    uint32_t swizzle = 0;
    if (Latte::TM_IsMacroTiled(tileMode)) {
        swizzle = addr & 0x700;
        addr &= ~0x700u;
    }
    SurfaceDesc d;
    d.addr = addr;
    d.mipAddr = mipAddr;
    d.width = width;
    d.height = height;
    d.slices = depth;
    d.pitch = pitch;
    d.mips = w5.get_LAST_LEVEL() + 1;
    d.format = (uint32_t)LatteTexture_ReconstructGX2Format(w1, w4);
    d.dim = (uint32_t)dim;
    d.tileMode = (uint32_t)tileMode;
    d.swizzle = swizzle;
    d.isDepth = false;
    // a depth-compare fetch (shadow maps) reads the depth buffer the game rendered at this address.
    // Look among depth surfaces first, like the Vulkan renderer: the generic lookup below also
    // accepts colour surfaces, and a GPU-written colour surface of the same size and format at that
    // address (memory the game used for something else earlier in the session) would win over it,
    // which makes the result depend on what was rendered before. No depth surface there yet (the
    // map isn't rendered): the generic lookup as before, no CPU-uploaded depth texture.
    if (isDepthSampler) {
        SurfaceDesc dd = d;
        dd.isDepth = true;
        if (Surface* s = find_surface(dd, false); s && s->gpuWritten) return s;
    }
    Surface* s = find_or_create_surface(d, false);
    if (s && !s->gpuWritten && s->lastCheckedFrame != R.frame) {
        s->lastCheckedFrame = R.frame;
        check_texture(s);
    }
    return s;
}

// Guest ranges of every level the upload reads (base first), computed once: a Surface's geometry
// never changes after creation.
static const std::vector<std::pair<uint32_t, uint32_t>>& level_ranges(Surface* s) {
    if (!s->levelRanges.empty()) return s->levelRanges;
    for (uint32_t level = 0; level < s->mips; level++) {
        uint32_t base;
        if (level == 0) base = s->addr;
        else if (!s->mipAddr) break;
        else if (level == 1) base = s->mipAddr;
        else {
            // mip offsets relative to the mip chain start
            uint32_t sliceOffset = 0, sliceSize = 0;
            sint32 sub = 0;
            LatteAddrLib::CalculateMipAndSliceAddr(s->addr, s->mipAddr, (Latte::E_GX2SURFFMT)s->format, s->width, s->height,
                                                   s->slices, (Latte::E_DIM)s->dim, (Latte::E_HWTILEMODE)s->tileMode,
                                                   s->swizzle, 0, level, 0, &sliceOffset, &sliceSize, &sub);
            base = sliceOffset;
        }
        LatteAddrLib::AddrSurfaceInfo_OUT info{};
        LatteAddrLib::GX2CalculateSurfaceInfo((Latte::E_GX2SURFFMT)s->format, s->width, s->height, s->slices, (Latte::E_DIM)s->dim,
                                              Latte::MakeGX2TileMode((Latte::E_HWTILEMODE)s->tileMode), 0, level, &info);
        // clamp to the 4 GiB guest space (a bogus descriptor must not make the hash read past it)
        uint32_t size = (uint32_t)std::min<uint64_t>(info.surfSize, 0x100000000ull - base);
        s->levelRanges.push_back({base, size});
    }
    s->dataSize = s->levelRanges[0].second;
    return s->levelRanges;
}

// Has the CPU changed this texture since its last check? Exact with write tracking (write_watch.h):
// its pages were write-protected at that check, so any write since has stamped them. Changes the
// game announces (GX2Invalidate on the range, GX2CopySurface into it, a loaded save state) set dirty.
// Then every byte of every level is hashed and the texture re-uploaded if the hash differs.
// Without write tracking (page protection unavailable on the host): the old sampled check, 256 words
// per level every frame plus a full check every 64 frames, which can show a changed texture late.
static void check_texture(Surface* s) {
    const auto& ranges = level_ranges(s);
    bool full = s->dirty || !s->watched;
    if (wwatch::active()) {
        if (!full)
            for (auto& [a, n] : ranges)
                if (wwatch::written_since(a, n, s->watchStamp)) {
                    full = true;
                    // debug: WWHD_LOG_TEXCHECK=1 logs textures re-checked because their pages were written
                    static const bool log = getenv("WWHD_LOG_TEXCHECK") != nullptr;
                    static int logged = 0;
                    if (log && logged++ < 400)
                        LOG("[texcheck] frame %llu %08X %ux%u fmt %X mips %u: write at %08X+%X", (unsigned long long)R.frame, s->addr,
                            s->width, s->height, s->format, s->mips, a, n);
                    break;
                }
        if (!full) return;
        // arm before reading: a write from now on faults and stamps the pages after this stamp
        uint64_t stamp = ~0ull;
        for (auto& [a, n] : ranges) stamp = std::min(stamp, wwatch::arm(a, n));
        s->watchStamp = stamp;
    } else {
        full = full || ((R.frame + (s->addr >> 12)) & 63) == 0;
        uint64_t h = sparse_hash(s);
        if (h != s->sparseHash) full = true;
        s->sparseHash = h;
        if (!full) return;
    }
    s->watched = true;
    g_stat_full_checks++;
    upload_surface(s);
    s->dirty = false;
}

// ---------------------------------------------------------------- upload (detile + convert)
static void decode_level(Surface* s, uint32_t level, uint32_t base, std::vector<uint8_t>& out, uint32_t& outW,
                         uint32_t& outH, uint32_t& outSlices) {
    const FormatInfo& f = s->fmt;
    uint32_t w = std::max(s->width >> level, 1u), h = std::max(s->height >> level, 1u);
    uint32_t slices = s->dim == (uint32_t)Latte::E_DIM::DIM_3D ? std::max(s->slices >> level, 1u) : s->slices;
    uint32_t bw = f.compressed ? (w + 3) / 4 : w, bh = f.compressed ? (h + 3) / 4 : h;
    outW = w;
    outH = h;
    outSlices = slices;

    // level geometry from the address library
    LatteAddrLib::AddrSurfaceInfo_OUT info{};
    LatteAddrLib::GX2CalculateSurfaceInfo((Latte::E_GX2SURFFMT)s->format, s->width, s->height, s->slices,
                                          (Latte::E_DIM)s->dim, Latte::MakeGX2TileMode((Latte::E_HWTILEMODE)s->tileMode),
                                          0, level, &info);
    uint32_t pitch = info.pitch, height = info.height;
    auto tm = (Latte::E_HWTILEMODE)info.hwTileMode;
    uint32_t bpp = f.bytesPerBlock * 8;
    uint32_t pipeSwizzle = (s->swizzle >> 8) & 1, bankSwizzle = (s->swizzle >> 9) & 3;
    // small mips of macro-tiled surfaces drop the swizzle
    out.assign((size_t)bw * bh * slices * f.hostBytesPerBlock, 0);
    std::vector<uint8_t> row(bw * f.bytesPerBlock);
    const uint8_t* src = mem::ptr(base);
    for (uint32_t z = 0; z < slices; z++) {
        LatteAddrLib::CachedSurfaceAddrInfo ci;
        bool macro = Latte::TM_IsMacroTiled(tm);
        if (macro)
            LatteAddrLib::SetupCachedSurfaceAddrInfo(&ci, z, 0, bpp, pitch, height, slices, 1, tm, false, pipeSwizzle, bankSwizzle);
        for (uint32_t y = 0; y < bh; y++) {
            for (uint32_t x = 0; x < bw; x++) {
                uint32_t off;
                if (tm == Latte::E_HWTILEMODE::TM_LINEAR_GENERAL || tm == Latte::E_HWTILEMODE::TM_LINEAR_ALIGNED)
                    off = LatteAddrLib::ComputeSurfaceAddrFromCoordLinear(x, y, z, 0, bpp, pitch, height, slices);
                else if (!macro)
                    off = LatteAddrLib::ComputeSurfaceAddrFromCoordMicroTiled(x, y, z, bpp, pitch, height, tm, false);
                else
                    off = LatteAddrLib::ComputeSurfaceAddrFromCoordMacroTiledCached(x, y, &ci);
                memcpy(&row[x * f.bytesPerBlock], src + off, f.bytesPerBlock);
            }
            uint8_t* dst = &out[((size_t)z * bh + y) * bw * f.hostBytesPerBlock];
            if (f.convert == Convert::NONE) memcpy(dst, row.data(), row.size());
            else convert_row(f.convert, row.data(), dst, bw);
        }
    }
}

enum class SurfaceDebugMode { Draw, SelectedTexture };
static SurfaceDebugInfo surface_debug_info_impl(const Surface* surface, SurfaceDebugMode mode) {
    SurfaceDebugInfo debug;
    if (!surface || !draw_diagnostics_active()) return debug;
    auto* s = const_cast<Surface*>(surface);
    LatteAddrLib::AddrSurfaceInfo_OUT info{};
    LatteAddrLib::GX2CalculateSurfaceInfo((Latte::E_GX2SURFFMT)s->format, s->width, s->height, s->slices, (Latte::E_DIM)s->dim,
                                          Latte::MakeGX2TileMode((Latte::E_HWTILEMODE)s->tileMode), 0, 0, &info);
    debug.layoutPitch = info.pitch;
    debug.layoutHeight = info.height;
    debug.dataSize = (uint32_t)std::min<uint64_t>(info.surfSize, 0xFFFFFFFFull);
    const bool candidateMask = mode == SurfaceDebugMode::Draw && s->format == 0x01 && s->mips == 1 && s->slices == 1 &&
                               ((s->width == 32 && s->height == 46) || (s->width == 24 && s->height == 40));
    const bool selectedTexture = mode == SurfaceDebugMode::SelectedTexture && s->dim == (uint32_t)Latte::E_DIM::DIM_2D &&
                                 s->mips == 1 && s->slices == 1;
    if ((!candidateMask && !selectedTexture) || s->gpuWritten || !s->tex) return debug;
    const auto& ranges = level_ranges(s);
    constexpr uint64_t kMaxSelectedTextureBytes = 512 * 1024;
    if (ranges.size() != 1 || ranges[0].second != info.surfSize ||
        (selectedTexture && ranges[0].second > kMaxSelectedTextureBytes)) return debug;
    debug.rawHash = XXH3_64bits(mem::ptr(ranges[0].first), ranges[0].second);
    debug.rawHashValid = true;
    const uint64_t blockWidth = s->fmt.compressed ? (s->width + 3) / 4 : s->width;
    const uint64_t blockHeight = s->fmt.compressed ? (s->height + 3) / 4 : s->height;
    const uint64_t decodedSize = blockWidth * blockHeight * s->slices * s->fmt.hostBytesPerBlock;
    if (selectedTexture && decodedSize > kMaxSelectedTextureBytes) return debug;
    std::vector<uint8_t> pixels;
    uint32_t width, height, slices;
    decode_level(s, 0, ranges[0].first, pixels, width, height, slices);
    const uint64_t expectedPixels = (uint64_t)width * height * s->fmt.hostBytesPerBlock;
    if (width == s->width && height == s->height && slices == 1 && pixels.size() == (size_t)expectedPixels) {
        debug.pixelHash = XXH3_64bits(pixels.data(), pixels.size());
        debug.pixelHashValid = true;
    }
    return debug;
}

SurfaceDebugInfo surface_debug_info(const Surface* surface) { return surface_debug_info_impl(surface, SurfaceDebugMode::Draw); }
SurfaceDebugInfo surface_debug_info_for_trace(const Surface* surface) { return surface_debug_info_impl(surface, SurfaceDebugMode::SelectedTexture); }

// fallback without write tracking: 256 words spread over each level
static uint64_t sparse_hash(Surface* s) {
    uint64_t h = 0xcbf29ce484222325ull;
    for (auto& [a, n] : level_ranges(s)) {
        uint32_t step = std::max<uint32_t>((n / 256) & ~7u, 8);
        for (uint32_t o = 0; o + 8 <= n; o += step) {
            uint64_t v;
            memcpy(&v, mem::ptr(a + o), 8);
            h = (h ^ v) * 0x100000001b3ull;
        }
    }
    return h;
}

// every byte of every level the upload reads
uint64_t g_stat_hashed_bytes;
static uint64_t content_hash(Surface* s) {
    uint64_t h = 0;
    for (auto& [a, n] : level_ranges(s)) {
        h = XXH3_64bits_withSeed(mem::ptr(a), n, h);
        g_stat_hashed_bytes += n;
    }
    return h;
}

void upload_surface(Surface* s) {
    if (!s->tex || s->gpuWritten) return;
    const FormatInfo& f = s->fmt;
    const auto& ranges = level_ranges(s);
    uint64_t hash = content_hash(s);
    if (hash == s->contentHash && s->writeSeq) return;
    s->contentHash = hash;
    s->writeSeq = next_write_seq();  // fresh CPU data is now the newest version of this memory
    g_stat_uploads++;

    std::vector<uint8_t> data;
    id<MTLBuffer> staging = nil;
    end_encoder();
    id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
    for (uint32_t level = 0; level < ranges.size(); level++) {
        uint32_t base = ranges[level].first;
        uint32_t w, h, slices;
        decode_level(s, level, base, data, w, h, slices);
        uint32_t bw = f.compressed ? (w + 3) / 4 : w, bh = f.compressed ? (h + 3) / 4 : h;
        staging = [R.device newBufferWithBytes:data.data() length:data.size() options:MTLResourceStorageModeShared];
        bool is3D = s->tex.textureType == MTLTextureType3D;
        uint32_t layers = is3D ? 1 : (s->tex.textureType == MTLTextureTypeCube ? 6 : (uint32_t)s->tex.arrayLength);
        uint32_t perSlice = bw * bh * f.hostBytesPerBlock;
        for (uint32_t z = 0; z < (is3D ? 1 : std::min(slices, layers)); z++) {
            [blit copyFromBuffer:staging
                     sourceOffset:(NSUInteger)z * perSlice
                sourceBytesPerRow:bw * f.hostBytesPerBlock
              sourceBytesPerImage:perSlice
                       sourceSize:MTLSizeMake(f.compressed ? bw * 4 : w, f.compressed ? bh * 4 : h, is3D ? slices : 1)
                        toTexture:s->tex
                 destinationSlice:z
                 destinationLevel:level
                destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
    }
    [blit endEncoding];
}

// ---------------------------------------------------------------- GX2CopySurface
static uint32_t level_address(GX2Surface* s, uint32_t level) {
    if (level == 0) return s->imagePtr;
    if (level == 1) return s->mipPtr;
    return s->mipPtr + s->mipOffset[level - 1];
}

static uint32_t element_offset(const LatteAddrLib::AddrSurfaceInfo_OUT& info, Latte::E_HWTILEMODE tm, uint32_t x, uint32_t y,
                               uint32_t slice, uint32_t bpp, uint32_t swizzle, LatteAddrLib::CachedSurfaceAddrInfo* ci) {
    if (tm == Latte::E_HWTILEMODE::TM_LINEAR_GENERAL || tm == Latte::E_HWTILEMODE::TM_LINEAR_ALIGNED)
        return LatteAddrLib::ComputeSurfaceAddrFromCoordLinear(x, y, slice, 0, bpp, info.pitch, info.height, info.depth);
    if (!Latte::TM_IsMacroTiled(tm))
        return LatteAddrLib::ComputeSurfaceAddrFromCoordMicroTiled(x, y, slice, bpp, info.pitch, info.height, tm, false);
    return LatteAddrLib::ComputeSurfaceAddrFromCoordMacroTiledCached(x, y, ci);
}

// ---------------------------------------------------------------- write-back to guest memory
// Render results stay on the GPU, except where the game reads them with the CPU: render targets and
// GX2CopySurface destinations with a linear tile mode (as Cemu reads back linear surfaces). The Picto
// Box renders its picture into a linear-aligned target and JPEG-encodes it from guest memory (issue
// #53). Texels are written at the guest size; only formats whose host texels are the guest's bytes.
static bool can_write_back(const Surface* img) {
    const FormatInfo& f = img->fmt;
    bool ok = img->tex && !f.compressed && !f.depth && f.convert == Convert::NONE && f.hostBytesPerBlock == f.bytesPerBlock &&
              img->tex.textureType == MTLTextureType2D;
    if (!ok) {
        static bool logged = false;
        if (!logged) LOG("[gfx] linear surface %08X (format %X) is not written back to guest memory", img->addr, img->format);
        logged = true;
    }
    return ok;
}
// the texels of img at the guest size w x h (its top-left), read from the GPU (waits for it)
static std::vector<uint8_t> read_guest_texels(Surface* img, uint32_t w, uint32_t h) {
    const uint32_t bytes = img->fmt.bytesPerBlock;
    id<MTLTexture> src = img->tex;
    if (src.width != img->width || src.height != img->height) {
        // a render target at the internal resolution: filter it down to the guest size first
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:img->width
                                                                                     height:img->height mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> small = [R.device newTextureWithDescriptor:td];
        end_encoder();
        resample(src, small, img->fmt, 1);
        src = small;
    }
    id<MTLBuffer> buf = [R.device newBufferWithLength:(NSUInteger)w * h * bytes options:MTLResourceStorageModeShared];
    end_encoder();
    id<MTLBlitCommandEncoder> b = [command_buffer() blitCommandEncoder];
    [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:buf destinationOffset:0 destinationBytesPerRow:(NSUInteger)w * bytes destinationBytesPerImage:(NSUInteger)w * h * bytes];
    [b endEncoding];
    wait_idle();
    const uint8_t* raw = (const uint8_t*)buf.contents;
    return std::vector<uint8_t>(raw, raw + (size_t)w * h * bytes);
}
// GX2CopySurface done on the GPU into a linear destination: the game reads it once the call returns
static void write_back_linear_copy(Surface* img, GX2Surface* d, uint32_t dbase, uint32_t dstMip, uint32_t dstSlice, uint32_t w, uint32_t h) {
    LatteAddrLib::AddrSurfaceInfo_OUT di{};
    LatteAddrLib::GX2CalculateSurfaceInfo(d->format, d->width, d->height, d->depth, d->dim, d->tileMode, d->aa, dstMip, &di);
    auto dtm = (Latte::E_HWTILEMODE)di.hwTileMode;
    if ((dtm != Latte::E_HWTILEMODE::TM_LINEAR_GENERAL && dtm != Latte::E_HWTILEMODE::TM_LINEAR_ALIGNED) || dstSlice >= di.depth ||
        !can_write_back(img))
        return;
    const uint32_t bytes = img->fmt.bytesPerBlock;
    const uint64_t r0 = rprof::now_ns();
    auto texels = read_guest_texels(img, w, h);
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x++)
            memcpy(mem::ptr(dbase + element_offset(di, dtm, x, y, dstSlice, bytes * 8, d->swizzle, nullptr)),
                   texels.data() + ((size_t)y * w + x) * bytes, bytes);
    img->writtenBackSeq = img->writeSeq;
    rprof::add_write_back(0, 1, texels.size(), rprof::now_ns() - r0);
}
// GX2DrawDone: linear render targets drawn since their last write-back
void write_back_linear_targets() {
    const uint64_t t0 = rprof::now_ns();
    uint64_t readNs = 0, bytesDone = 0;
    uint32_t count = 0;
    // linear aligned only: a tile mode of 0 can also be GX2's "default" (a tiled copy destination)
    for (Surface* s : R.linearTargets) {
        if (!s->gpuWritten || s->writtenBackSeq == s->writeSeq || !s->tex) continue;
        s->writtenBackSeq = s->writeSeq;
        if (s->slices != 1 || !can_write_back(s)) continue;
        const uint32_t addr = s->addr;
        const uint32_t bytes = s->fmt.bytesPerBlock, pitch = std::max(s->pitch, s->width);
        const uint64_t r0 = rprof::now_ns();
        auto texels = read_guest_texels(s, s->width, s->height);
        for (uint32_t y = 0; y < s->height; y++)
            memcpy(mem::ptr(addr + y * pitch * bytes), texels.data() + (size_t)y * s->width * bytes, (size_t)s->width * bytes);
        readNs += rprof::now_ns() - r0;
        bytesDone += texels.size();
        count++;
    }
    rprof::add_write_back(std::max<uint64_t>(1, rprof::now_ns() - t0 - readNs), count, bytesDone, readNs);
}

void copy_surface_impl(uint32_t srcAddr, uint32_t srcMip, uint32_t srcSlice, uint32_t dstAddr, uint32_t dstMip, uint32_t dstSlice) {
    auto* s = (GX2Surface*)mem::ptr(srcAddr);
    auto* d = (GX2Surface*)mem::ptr(dstAddr);
    uint32_t sbase = level_address(s, srcMip), dbase = level_address(d, dstMip);
    uint32_t w = std::max<uint32_t>(s->width >> srcMip, 1), h = std::max<uint32_t>(s->height >> srcMip, 1);
    FormatInfo f = format_info((uint32_t)s->format.value(), false);

    // GPU-produced source: copy texture to texture. Of the source's GPU images (format views), the
    // one in the source's format, else the most recent; a newer view is copied into it first.
    Surface* gpuSrc = nullptr;
    auto range = R.surfaces.equal_range(sbase);
    for (auto it = range.first; it != range.second; ++it) {
        Surface* c = it->second.get();
        if (!c->gpuWritten || c->width != w || c->height != h) continue;
        auto key = [&](Surface* x) { return std::make_pair(x->format == (uint32_t)s->format.value(), x->writeSeq); };
        if (!gpuSrc || key(c) > key(gpuSrc)) gpuSrc = c;
    }
    if (gpuSrc) {
        Surface* src = adopt_newer_alias(gpuSrc);
        SurfaceDesc dd;
        dd.addr = dbase;
        dd.width = std::max<uint32_t>(d->width >> dstMip, 1);
        dd.height = std::max<uint32_t>(d->height >> dstMip, 1);
        dd.pitch = d->pitch;
        dd.format = (uint32_t)d->format.value();
        dd.tileMode = (uint32_t)d->tileMode.value();
        dd.isDepth = src->isDepth;  // a depth buffer converted to a texture stays a depth image (sampled as one)
        Surface* dst = find_or_create_surface(dd, true);
        if (!dst || dst->fmt.pixel != src->fmt.pixel) return;
        end_encoder();
        // region in guest pixels, then in each texture's pixels (both may be scaled for the internal resolution)
        uint32_t cw = std::min(w, dst->width), ch = std::min(h, dst->height);
        uint32_t spw = std::min<uint32_t>((uint32_t)std::lround(cw * src->sx), (uint32_t)src->tex.width);
        uint32_t sph = std::min<uint32_t>((uint32_t)std::lround(ch * src->sy), (uint32_t)src->tex.height);
        uint32_t dpw = std::min<uint32_t>((uint32_t)std::lround(cw * dst->sx), (uint32_t)dst->tex.width);
        uint32_t dph = std::min<uint32_t>((uint32_t)std::lround(ch * dst->sy), (uint32_t)dst->tex.height);
        if (spw == dpw && sph == dph) {
            id<MTLBlitCommandEncoder> b = [command_buffer() blitCommandEncoder];
            [b copyFromTexture:src->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(spw, sph, 1)
                     toTexture:dst->tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [b endEncoding];
        } else {
            resample(src->tex, dst->tex, dst->fmt, 1, (float)spw / src->tex.width, (float)sph / src->tex.height, dpw, dph);
        }
        mark_gpu_written(dst);
        write_back_linear_copy(dst, d, dbase, dstMip, dstSlice, cw, ch);
        return;
    }

    // CPU-produced source: re-tile in guest memory; texture uploads pick up the change
    LatteAddrLib::AddrSurfaceInfo_OUT si{}, di{};
    LatteAddrLib::GX2CalculateSurfaceInfo(s->format, s->width, s->height, s->depth, s->dim, s->tileMode, s->aa, srcMip, &si);
    LatteAddrLib::GX2CalculateSurfaceInfo(d->format, d->width, d->height, d->depth, d->dim, d->tileMode, d->aa, dstMip, &di);
    auto stm = (Latte::E_HWTILEMODE)si.hwTileMode, dtm = (Latte::E_HWTILEMODE)di.hwTileMode;
    uint32_t bpp = f.bytesPerBlock * 8;
    uint32_t bw = f.compressed ? (w + 3) / 4 : w, bh = f.compressed ? (h + 3) / 4 : h;
    uint32_t sswz = s->swizzle, dswz = d->swizzle;
    LatteAddrLib::CachedSurfaceAddrInfo sci, dci;
    if (Latte::TM_IsMacroTiled(stm))
        LatteAddrLib::SetupCachedSurfaceAddrInfo(&sci, srcSlice, 0, bpp, si.pitch, si.height, si.depth, 1, stm, false, (sswz >> 8) & 1, (sswz >> 9) & 3);
    if (Latte::TM_IsMacroTiled(dtm))
        LatteAddrLib::SetupCachedSurfaceAddrInfo(&dci, dstSlice, 0, bpp, di.pitch, di.height, di.depth, 1, dtm, false, (dswz >> 8) & 1, (dswz >> 9) & 3);
    // debug: WWHD_COPYDBG=1 logs each CPU-path copy (destination range, time); see GX2CopySurface
    static const bool dbg = getenv("WWHD_COPYDBG") != nullptr;
    if (dbg)
        LOG("[copydbg] exec cpu copy t=%.3f src %08X dst %08X..%08X (%ux%u fmt %X tm %u->%u)", timebase::now() / (double)timebase::kTicksPerSec,
            sbase, dbase, dbase + (uint32_t)di.surfSize, w, h, (uint32_t)s->format.value(), (uint32_t)stm, (uint32_t)dtm);
    for (uint32_t y = 0; y < bh; y++)
        for (uint32_t x = 0; x < bw; x++) {
            uint32_t so = element_offset(si, stm, x, y, srcSlice, bpp, sswz, &sci);
            uint32_t dofs = element_offset(di, dtm, x, y, dstSlice, bpp, dswz, &dci);
            memcpy(mem::ptr(dbase + dofs), mem::ptr(sbase + so), f.bytesPerBlock);
        }
    // force re-upload of any texture made from the destination
    auto dr = R.surfaces.equal_range(dbase);
    for (auto it = dr.first; it != dr.second; ++it) {
        it->second->lastCheckedFrame = ~0ull;
        it->second->dirty = true;
    }
}

}  // namespace gfx

namespace gfx {
// a save state replaced guest memory: every CPU-side texture gets a full check on next use (render
// targets keep their GPU contents; the next frame redraws them)
void ss_reset_surfaces() {
    for (auto& [a, s] : R.surfaces) {
        s->dirty = true;
        s->lastCheckedFrame = ~0ull;
    }
}
}  // namespace gfx
