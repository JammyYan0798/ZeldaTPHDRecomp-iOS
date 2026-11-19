#include "gfx/native_resolution_geometry.h"

#include <cassert>
#include <cmath>
#include <limits>

int main() {
    using namespace gfx::native_resolution;
    auto fit = fit_crop(2360, 1640, 16.0 / 9.0, false);
    assert(fit && fit.width == 2360 && fit.height == 1328);
    assert(std::fabs(fit.scale - 1328.0f / 1080.0f) < 0.001f);

    auto crop = fit_crop(2732, 2048, 16.0 / 9.0, true);
    assert(crop && crop.width == 3641 && crop.height == 2048);
    assert(std::fabs(crop.scale - 2048.0f / 1080.0f) < 0.001f);

    auto narrow = fit_crop(2732, 2048, 4.0 / 3.0, false);
    assert(narrow && narrow.width == 2731 && narrow.height == 2048);
    assert(std::fabs(narrow.scale - 2731.0f / 1920.0f) < 0.001f);

    assert(fit_crop(4000, 3000, 16.0 / 9.0, true).error == Error::DimensionLimit);
    assert(fit_crop(3000, 3000, 1.0, true).error == Error::PixelLimit);
    assert(fit_crop(700, 400, 16.0 / 9.0, false).error == Error::ScaleLimit);
    assert(fit_crop(2732, 2048, std::numeric_limits<double>::quiet_NaN(), false).error == Error::InvalidGeometry);
    assert(restore_mode(true, false));
    assert(!restore_mode(true, true));
    assert(!restore_mode(false, false));
}
