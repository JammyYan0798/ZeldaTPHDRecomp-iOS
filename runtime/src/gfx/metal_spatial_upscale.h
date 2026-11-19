#pragma once
#import <Metal/Metal.h>

namespace gfx {

// Disabled by default. The settings UI may change this at runtime; the environment variable is
// useful for controlled experiments before a UI is wired.
bool spatial_upscale_enabled();
void set_spatial_upscale_enabled(bool enabled);
bool spatial_upscale_failed();

// Encodes an optional MetalFX spatial pass in the caller's command buffer. Returns nil when the
// device, dimensions, input format, texture usage, or scaler is unavailable so presentation can
// keep using its existing sampler path.
id<MTLTexture> spatial_upscale(id<MTLDevice> device, id<MTLCommandBuffer> commandBuffer, id<MTLTexture> input,
                               NSUInteger outputWidth, NSUInteger outputHeight);

// Call after draining the graphics queue when releasing presentation resources (for example, when
// the app enters the background).
void reset_spatial_upscale();

}  // namespace gfx
