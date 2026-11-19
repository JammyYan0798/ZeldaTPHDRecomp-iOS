#pragma once
namespace ios {
constexpr bool touch_game_controls_visible(bool manually_visible, bool physical_controller_connected) {
    return manually_visible && !physical_controller_connected;
}
}
#ifdef __OBJC__
@class UIViewController;
namespace ios {
void install_controls(UIViewController* vc);
void set_physical_controller_connected(bool connected);
}
#endif
namespace ios { void release_controls(); }
