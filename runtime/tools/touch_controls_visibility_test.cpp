#include "../src/platform/ios/controls.h"

#include <cstdio>

int main() {
    int failed = 0;
    auto check = [&](bool expected, bool manually_visible, bool physical_controller_connected) {
        const bool actual = ios::touch_game_controls_visible(manually_visible, physical_controller_connected);
        if (actual != expected) {
            std::fprintf(stderr, "visibility mismatch: manual=%d physical=%d expected=%d actual=%d\n",
                         manually_visible, physical_controller_connected, expected, actual);
            ++failed;
        }
    };
    check(true, true, false);   // No controller: retain the current default visible layout.
    check(false, true, true);   // A physical controller hides only the game controls.
    check(false, false, false); // A future/manual hidden preference remains respected after disconnect.
    check(false, false, true);
    std::fprintf(stderr, "touch_controls_visibility_test: %s\n", failed ? "failed" : "passed");
    return failed ? 1 : 0;
}
