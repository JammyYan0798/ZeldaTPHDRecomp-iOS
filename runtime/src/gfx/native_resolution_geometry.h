#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace gfx::native_resolution {

inline constexpr uint32_t kMaxDimension = 4096;
inline constexpr uint64_t kMaxPixels = 8'294'400;
inline constexpr float kMinScale = 0.5f;
inline constexpr float kMaxScale = 4.0f;

enum class Error : uint8_t { None, InvalidGeometry, DimensionLimit, PixelLimit, ScaleLimit };

struct Geometry {
    uint32_t width = 0, height = 0;
    float scale = 1.0f;
    Error error = Error::None;
    explicit operator bool() const { return error == Error::None; }
};

// The environment scale remains authoritative over a saved Native choice.
constexpr bool restore_mode(bool saved_native, bool res_scale_overridden) {
    return saved_native && !res_scale_overridden;
}

inline Geometry fit_crop(double drawable_width, double drawable_height, double aspect, bool crop) {
    auto fail = [](Error error) { Geometry g; g.error = error; return g; };
    if (!std::isfinite(drawable_width) || !std::isfinite(drawable_height) || !std::isfinite(aspect) ||
        drawable_width < 1.0 || drawable_height < 1.0 || aspect <= 0.5 || aspect >= 8.0)
        return fail(Error::InvalidGeometry);

    const double q = crop ? std::max(drawable_width / aspect, drawable_height)
                           : std::min(drawable_width / aspect, drawable_height);
    const double width = aspect * q;
    if (!std::isfinite(width) || !std::isfinite(q) || width < 0.5 || q < 0.5)
        return fail(Error::InvalidGeometry);
    if (width > kMaxDimension + 0.5 || q > kMaxDimension + 0.5)
        return fail(Error::DimensionLimit);

    const uint32_t w = static_cast<uint32_t>(std::floor(width + 0.5));
    const uint32_t h = static_cast<uint32_t>(std::floor(q + 0.5));
    if (!w || !h) return fail(Error::InvalidGeometry);
    if (w > kMaxDimension || h > kMaxDimension) return fail(Error::DimensionLimit);
    if (uint64_t(w) * h > kMaxPixels) return fail(Error::PixelLimit);

    const double scale = aspect >= 16.0 / 9.0 ? double(h) / 1080.0 : double(w) / 1920.0;
    if (!std::isfinite(scale) || scale < kMinScale || scale > kMaxScale)
        return fail(Error::ScaleLimit);
    return {w, h, static_cast<float>(scale), Error::None};
}

}  // namespace gfx::native_resolution
