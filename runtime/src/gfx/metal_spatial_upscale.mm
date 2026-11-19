#include "metal_spatial_upscale.h"

#ifdef WWHD_IOS
#import <MetalFX/MetalFX.h>

#include <atomic>
#include <cstdlib>
#include <cstring>

#include "runtime.h"

namespace gfx {
namespace {

static std::atomic<bool> g_enabled{[] {
    const char* value = std::getenv("WWHD_METALFX_SPATIAL");
    return value && std::strcmp(value, "1") == 0;
}()};
static std::atomic<bool> g_failed{false};  // latched until the user disables the experiment or GPU resources reset

struct ScalerCache {
    id<MTLDevice> device = nil;
    id<MTLFXSpatialScaler> scaler = nil;
    id<MTLTexture> output = nil;
    NSUInteger inputWidth = 0, inputHeight = 0, outputWidth = 0, outputHeight = 0;
    MTLPixelFormat format = MTLPixelFormatInvalid;
    MTLTextureUsage inputUsage = MTLTextureUsageUnknown;
    bool attempted = false, failed = false;
};

static ScalerCache g_cache;

static bool supported_format(MTLPixelFormat format) {
    switch (format) {
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB: return true;
    default: return false;
    }
}

static void clear_cache() {
    g_cache.output = nil;
    g_cache.scaler = nil;
    g_cache.device = nil;
    g_cache.inputWidth = g_cache.inputHeight = g_cache.outputWidth = g_cache.outputHeight = 0;
    g_cache.format = MTLPixelFormatInvalid;
    g_cache.inputUsage = MTLTextureUsageUnknown;
    g_cache.attempted = g_cache.failed = false;
}

static id<MTLTexture> configure(id<MTLDevice> device, id<MTLTexture> input, NSUInteger outputWidth,
                                NSUInteger outputHeight) {
    if (g_cache.device == device && g_cache.inputWidth == input.width && g_cache.inputHeight == input.height &&
        g_cache.outputWidth == outputWidth && g_cache.outputHeight == outputHeight && g_cache.format == input.pixelFormat &&
        g_cache.inputUsage == input.usage && g_cache.attempted) {
        if (g_cache.failed) {
            g_failed = true;  // Re-arming after disable must restore the native-resolution fallback.
            return nil;
        }
        return g_cache.output;
    }

    clear_cache();
    g_cache.device = device;
    g_cache.inputWidth = input.width;
    g_cache.inputHeight = input.height;
    g_cache.outputWidth = outputWidth;
    g_cache.outputHeight = outputHeight;
    g_cache.format = input.pixelFormat;
    g_cache.inputUsage = input.usage;
    g_cache.attempted = true;

    if (![MTLFXSpatialScalerDescriptor supportsDevice:device]) {
        LOG("[gfx] MetalFX spatial unavailable on this Metal device");
        g_failed = true;
        g_cache.failed = true;
        return nil;
    }
    MTLFXSpatialScalerDescriptor* descriptor = [MTLFXSpatialScalerDescriptor new];
    descriptor.inputWidth = input.width;
    descriptor.inputHeight = input.height;
    descriptor.outputWidth = outputWidth;
    descriptor.outputHeight = outputHeight;
    descriptor.colorTextureFormat = input.pixelFormat;
    descriptor.outputTextureFormat = input.pixelFormat;
    // The game's TV scanout is SDR/display-referred; keep its sRGB-like values in perceptual space.
    descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    g_cache.scaler = [descriptor newSpatialScalerWithDevice:device];
    if (!g_cache.scaler) {
        LOG("[gfx] MetalFX spatial scaler creation failed; using the normal presentation sampler");
        g_failed = true;
        g_cache.failed = true;
        return nil;
    }
    if ((input.usage & g_cache.scaler.colorTextureUsage) != g_cache.scaler.colorTextureUsage) {
        LOG("[gfx] MetalFX spatial input texture usage is incompatible; using the normal presentation sampler");
        g_failed = true;
        g_cache.failed = true;
        return nil;
    }

    MTLTextureDescriptor* output = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:input.pixelFormat
                                                                                       width:outputWidth
                                                                                      height:outputHeight
                                                                                   mipmapped:NO];
    output.usage = g_cache.scaler.outputTextureUsage | MTLTextureUsageShaderRead;
    output.storageMode = MTLStorageModePrivate;
    g_cache.output = [device newTextureWithDescriptor:output];
    if (!g_cache.output) {
        LOG("[gfx] MetalFX spatial output allocation failed; using the normal presentation sampler");
        g_failed = true;
        g_cache.failed = true;
        return nil;
    }
    LOG("[gfx] MetalFX spatial scaler ready: %lux%lu -> %lux%lu, format %lu, color mode perceptual",
        (unsigned long)input.width, (unsigned long)input.height, (unsigned long)outputWidth, (unsigned long)outputHeight,
        (unsigned long)input.pixelFormat);
    return g_cache.output;
}

}  // namespace

bool spatial_upscale_enabled() { return g_enabled.load(std::memory_order_relaxed); }
void set_spatial_upscale_enabled(bool enabled) {
    g_enabled.store(enabled, std::memory_order_relaxed);
    if (!enabled) g_failed = false;  // permits the explicit low-resolution/bilinear comparison path; cache stays on GPU thread
}
bool spatial_upscale_failed() { return g_enabled.load(std::memory_order_relaxed) && g_failed.load(std::memory_order_relaxed); }

id<MTLTexture> spatial_upscale(id<MTLDevice> device, id<MTLCommandBuffer> commandBuffer, id<MTLTexture> input,
                               NSUInteger outputWidth, NSUInteger outputHeight) {
    if (!spatial_upscale_enabled() || !device || !commandBuffer || !input || !outputWidth || !outputHeight)
        return nil;
    if (outputWidth <= input.width || outputHeight <= input.height) {
        g_failed = true;
        return nil;
    }
    if (!supported_format(input.pixelFormat)) {
        static MTLPixelFormat lastReported = MTLPixelFormatInvalid;
        if (lastReported != input.pixelFormat) {
            LOG("[gfx] MetalFX spatial input format %lu is unsupported; using the normal presentation sampler",
                (unsigned long)input.pixelFormat);
            lastReported = input.pixelFormat;
        }
        g_failed = true;
        return nil;
    }
    id<MTLTexture> output = configure(device, input, outputWidth, outputHeight);
    if (!output) return nil;
    g_cache.scaler.colorTexture = input;
    g_cache.scaler.inputContentWidth = input.width;
    g_cache.scaler.inputContentHeight = input.height;
    g_cache.scaler.outputTexture = output;
    [g_cache.scaler encodeToCommandBuffer:commandBuffer];
    return output;
}

void reset_spatial_upscale() {
    clear_cache();
    g_failed = false;
}

}  // namespace gfx

#else

namespace gfx {
bool spatial_upscale_enabled() { return false; }
void set_spatial_upscale_enabled(bool) {}
bool spatial_upscale_failed() { return false; }
id<MTLTexture> spatial_upscale(id<MTLDevice>, id<MTLCommandBuffer>, id<MTLTexture>, NSUInteger, NSUInteger) { return nil; }
void reset_spatial_upscale() {}
}  // namespace gfx

#endif
