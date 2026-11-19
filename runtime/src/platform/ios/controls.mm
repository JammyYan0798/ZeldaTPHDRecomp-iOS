// Minimal multitouch controls for the initial iPad boot milestone.
#import <UIKit/UIKit.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <utility>
#include "controls.h"
#include "input.h"
#include "gfx/display_modes.h"
#include "overlay/overlay.h"

static input::PadState g_touch_pad;
static bool g_physical_controller_connected;
static constexpr bool g_touch_controls_manually_visible = true;  // Current iOS UI has no separate visibility preference.
static std::atomic<unsigned> g_connection_trace_count{0};
static void publish_pad() { input::set_virtual_pad(g_touch_pad); }
static bool connection_trace_enabled() {
    const char* value = std::getenv("WWHD_TEST_PRO_CONNECTION_TRACE");
    return value && std::strcmp(value, "1") == 0;
}

@interface TPStick : UIView
@property(nonatomic) BOOL rightStick;
@property(nonatomic, strong) UITouch* activeTouch;
@end
@implementation TPStick
- (void)update:(UITouch*)touch ending:(BOOL)ending {
    if (self.hidden || g_physical_controller_connected || !g_touch_controls_manually_visible) return;
    if (self.activeTouch && touch != self.activeTouch) return;
    if (!self.activeTouch && !ending) self.activeTouch = touch;
    CGPoint p = [touch locationInView:self];
    float radius = self.bounds.size.width * 0.42f;
    float x = ending ? 0 : (p.x - CGRectGetMidX(self.bounds)) / radius;
    float y = ending ? 0 : (CGRectGetMidY(self.bounds) - p.y) / radius;
    float length = std::hypot(x, y);
    if (length > 1) { x /= length; y /= length; }
    if (self.rightStick) { g_touch_pad.rx = x; g_touch_pad.ry = y; }
    else { g_touch_pad.lx = x; g_touch_pad.ly = y; }
    if (ending) self.activeTouch = nil;
    publish_pad();
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self update:touches.anyObject ending:NO]; }
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if ([touches containsObject:self.activeTouch]) [self update:self.activeTouch ending:NO];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if ([touches containsObject:self.activeTouch]) [self update:self.activeTouch ending:YES];
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self touchesEnded:touches withEvent:event]; }
@end

@interface TPControls : UIView
@property(nonatomic, strong) NSMutableArray<UIButton*>* buttons;
@property(nonatomic, strong) TPStick* leftStick;
@property(nonatomic, strong) TPStick* rightStick;
@property(nonatomic) CGRect lastSafeFrame;
@property(nonatomic) BOOL hasSafeFrame;
@end
static TPControls* g_controls;
static void update_game_control_visibility() {
    if (!g_controls) return;
    const BOOL visible = ios::touch_game_controls_visible(g_touch_controls_manually_visible,
                                                           g_physical_controller_connected);
    for (NSUInteger i = 0; i < 14; ++i) g_controls.buttons[i].hidden = !visible;
    g_controls.leftStick.hidden = !visible;
    g_controls.rightStick.hidden = !visible;
    g_controls.buttons[14].hidden = NO;  // Keep the settings entry reachable.
    if (connection_trace_enabled()) {
        const unsigned index = g_connection_trace_count.fetch_add(1, std::memory_order_relaxed);
        if (index < 8)
            std::fprintf(stderr, "[ios][test-pro-connection] controls physical=%d game_controls_hidden=%d settings_visible=%d\n",
                         g_physical_controller_connected, !visible, !g_controls.buttons[14].hidden);
    }
}
@implementation TPControls
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:p withEvent:event];
    return hit == self ? nil : hit;
}
- (UIButton*)button:(NSString*)title bits:(uint32_t)bits {
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.accessibilityLabel = title;
    b.tag = bits;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.55];
    b.layer.cornerRadius = 22;
    [b addTarget:self action:@selector(down:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [b addTarget:self action:@selector(up:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    [self addSubview:b];
    [self.buttons addObject:b];
    return b;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.buttons = [NSMutableArray new];
        for (auto item : {std::pair<const char*, uint32_t>{"A", input::kA}, {"B", input::kB}, {"X", input::kX}, {"Y", input::kY},
                         {"L", input::kL}, {"ZL", input::kZL}, {"R", input::kR}, {"ZR", input::kZR},
                         {"+", input::kPlus}, {"−", input::kMinus}, {"↑", input::kUp}, {"↓", input::kDown},
                         {"←", input::kLeft}, {"→", input::kRight}}) [self button:@(item.first) bits:item.second];
        UIButton* settings = [self button:@"设置" bits:0];
        [settings removeTarget:self action:NULL forControlEvents:UIControlEventAllEvents];
        [settings addTarget:self action:@selector(settings:) forControlEvents:UIControlEventTouchUpInside];
        self.leftStick = [[TPStick alloc] initWithFrame:CGRectZero];
        self.rightStick = [[TPStick alloc] initWithFrame:CGRectZero];
        self.rightStick.rightStick = YES;
        for (TPStick* stick in @[self.leftStick, self.rightStick]) {
            stick.backgroundColor = [UIColor colorWithWhite:0.8 alpha:0.2];
            stick.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
            stick.layer.borderWidth = 2;
            stick.accessibilityLabel = stick.rightStick ? @"Camera stick" : @"Movement stick";
            [self addSubview:stick];
        }
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    if (self.hasSafeFrame && !CGRectEqualToRect(safe, self.lastSafeFrame)) ios::release_controls();
    self.hasSafeFrame = YES;
    self.lastSafeFrame = safe;
    CGFloat w = safe.size.width, h = safe.size.height, x = safe.origin.x, y = safe.origin.y;
    CGFloat unit = MIN(56, MIN(w / 16, h / 9));
    self.leftStick.frame = CGRectMake(x + unit * 0.5, y + h - unit * 4, unit * 3, unit * 3);
    self.rightStick.frame = CGRectMake(x + w - unit * 7, y + h - unit * 3.6, unit * 2.5, unit * 2.5);
    self.leftStick.layer.cornerRadius = unit * 1.5;
    self.rightStick.layer.cornerRadius = unit * 1.25;
    const float positions[][2] = {{-1.4f,-2.8f},{-2.4f,-1.8f},{-2.4f,-3.8f},{-3.4f,-2.8f},
        {0.3f,0.3f},{1.6f,0.3f},{-2.6f,0.3f},{-1.3f,0.3f},
        {-1.3f,-1.2f},{-2.6f,-1.2f},{4.6f,-2.9f},{4.6f,-1.1f},{3.7f,-2.f},{5.5f,-2.f}};
    for (NSUInteger i = 0; i < 14; ++i) {
        float px = positions[i][0], py = positions[i][1];
        self.buttons[i].frame = CGRectMake(x + (px < 0 ? w + px * unit : px * unit),
            y + (py < 0 ? h + py * unit : py * unit), unit, unit);
    }
    self.buttons[14].frame = CGRectMake(x + w / 2 - unit * 1.5, y + 8, unit * 3, unit);
}
- (void)down:(UIButton*)button {
    if (button.hidden || g_physical_controller_connected || !g_touch_controls_manually_visible) return;
    g_touch_pad.buttons |= (uint32_t)button.tag;
    publish_pad();
}
- (void)up:(UIButton*)button { g_touch_pad.buttons &= ~(uint32_t)button.tag; publish_pad(); }
- (void)settings:(UIButton*)button { ios::release_controls(); overlay::set_open(!overlay::is_open()); }
@end

namespace ios {
void release_controls() {
    g_touch_pad = {};
    if (g_controls) {
        g_controls.leftStick.activeTouch = nil;
        g_controls.rightStick.activeTouch = nil;
    }
    publish_pad();
}
void set_physical_controller_connected(bool connected) {
    if (g_physical_controller_connected != connected) {
        release_controls();
        g_physical_controller_connected = connected;
    }
    update_game_control_visibility();
}
void install_controls(UIViewController* vc) {
    g_controls = [[TPControls alloc] initWithFrame:vc.view.bounds];
    g_controls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:g_controls];
    update_game_control_visibility();
}
}
