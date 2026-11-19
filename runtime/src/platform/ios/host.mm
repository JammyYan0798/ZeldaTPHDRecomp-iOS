// UIKit host, following the Wind Waker iPad port; TP's runtime and renderer stay intact.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <cerrno>
#include <condition_variable>
#include <cstdlib>
#include <climits>
#include <cmath>
#include <initializer_list>
#include <map>
#include <mutex>
#include <sys/acl.h>
#include <sys/stat.h>
#include <tuple>
#include <unistd.h>
#include "ios.h"
#include "controls.h"
#include "runtime.h"
#include "recomp_table.h"
#include "input.h"
#include "audio_out.h"
#include "aspect.h"
#include "interp.h"
#include "look.h"
#include "gfx/metal.h"
#include "gfx/metal_spatial_upscale.h"
#include "gfx/renderer.h"
#include "gfx/display_modes.h"
#ifdef WWHD_HAS_VULKAN
#include "gfx/vulkan/settings.h"
#endif
#include "gx2/gx2.h"
#include "overlay/hostui.h"
#include "overlay/overlay.h"
#include "imgui.h"
#include "backends/imgui_impl_metal.h"

@interface TPMetalView : UIView
@property(nonatomic, strong) UITouch* gamepadTouch;
@property(nonatomic) CGSize lastLayoutSize;
@property(nonatomic) CGFloat lastLayoutScale;
@property(nonatomic) BOOL hasLayoutGeometry;
@end

static UIWindow* g_window;
static TPMetalView* g_canvas;
static std::mutex g_gpu_mutex;
static std::condition_variable g_gpu_cv;
static bool g_active = true;
static bool g_running = false;

namespace ios {
void run_gpu(void (*fn)()) {
    std::unique_lock lock(g_gpu_mutex);
    g_gpu_cv.wait(lock, [] { return g_active; });
    @autoreleasepool { fn(); }
}
void set_active(bool active) {
    std::lock_guard lock(g_gpu_mutex);
    g_active = active;
    gfx::R.tv.visible = active;
    if (!active) {
        if (g_running) {
            render::wait_idle();
            // A previous frame may already be committed while R.cmd is nil.
            id<MTLCommandBuffer> drain = [gfx::R.queue commandBuffer];
            [drain commit];
            [drain waitUntilCompleted];
            gfx::reset_spatial_upscale();
        }
        release_controls();
        input::release_keys();
        input::set_touch(false, 0, 0);
        g_canvas.gamepadTouch = nil;
        overlay::mouse_button(0, false);
        audio::flush();
    } else g_gpu_cv.notify_all();
}
}

namespace gfx {
bool fxaa_enabled();
void dump_texture(id<MTLTexture>, const char*, bool, bool);
#include "present.inc"

bool host_setting(const char* key, std::string& value) {
    if (getenv("WWHD_NO_HOST_INPUT")) return false;
    id result = [NSUserDefaults.standardUserDefaults objectForKey:@(key)];
    if (![result isKindOfClass:NSString.class]) return false;
    value = [result UTF8String];
    return true;
}
void set_host_setting(const char* key, const std::string& value) {
    if (!getenv("WWHD_NO_HOST_INPUT"))
        [NSUserDefaults.standardUserDefaults setObject:@(value.c_str()) forKey:@(key)];
}
void run_appkit_loop() {} // UIApplicationMain owns the main thread.
void show_startup_notice(const std::string& title, const std::string& text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@(title.c_str())
            message:@(text.c_str()) preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [g_window.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}
void display_init() {
    CAMetalLayer* layer = (CAMetalLayer*)g_canvas.layer;
    layer.device = R.device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    R.tv.layer = layer;
    R.drc.visible = false;
    g_has_drc_window = false;
    g_mode = kDrcPip;
    g_corner = 1;
    display_env_overrides();
    overlay::set_density(g_canvas.contentScaleFactor);
    input::init();
    // Apply the saved Pro choice before main.cpp starts the guest, so its initial probe and
    // KPAD callback see the same mode as the settings overlay. The environment remains authoritative.
    if (!getenv("WWHD_PRO_CONTROLLER")) {
        std::string saved_pro;
        if (hostui::get("proController", saved_pro) && (saved_pro == "0" || saved_pro == "1"))
            input::set_pro_controller(saved_pro == "1");
    }
    create_present_pipeline();
    hostui::load_saved_options();
}
}

namespace hostui {
void post(std::function<void()> fn) { dispatch_async(dispatch_get_main_queue(), ^{ fn(); }); }
void choose_mod_source(bool, std::function<void(std::string)> chosen) { chosen({}); }
bool get(const char* k, std::string& v) { return gfx::host_setting(k, v); }
void set(const char* k, const std::string& v) { gfx::set_host_setting(k, v); }
static bool env_override(std::initializer_list<const char*> names) {
    for (const char* name : names)
        if (getenv(name)) return true;
    return false;
}
static void save_if_unoverridden(const char* key, std::initializer_list<const char*> env, const std::string& value) {
    if (!env_override(env)) set(key, value);
}
float res_scale() { return render::res_scale(); }
void set_res_scale(float s) {
    gfx::set_native_resolution_enabled(false);
    gfx::clear_custom_resolution();
    if (!getenv("WWHD_RES_SCALE")) set("nativeResolution", "0");
    if (!env_override({"WWHD_RES_SCALE"})) {
        set("customWidth", "0");
        set("customHeight", "0");
    }
    render::set_res_scale(s);
    if (!env_override({"WWHD_RES_SCALE"}) && std::isfinite(s) && s >= 0.5f && s <= 4.0f)
        set("resScale", std::to_string(s));
}
bool spatial_upscale_enabled() { return gfx::spatial_upscale_enabled(); }
void set_spatial_upscale_enabled(bool enabled) {
    gfx::set_spatial_upscale_enabled(enabled);
    if (!getenv("WWHD_METALFX_SPATIAL")) set("metalFxSpatial", enabled ? "1" : "0");
}
bool spatial_upscale_failed() { return gfx::spatial_upscale_failed(); }
std::string settings_font_path() {
    NSString* path = [NSBundle.mainBundle pathForResource:@"WWHDSettingsSansSC-Regular" ofType:@"ttf" inDirectory:@"fonts"];
    return path ? std::string(path.UTF8String) : std::string();
}
void set_native_resolution_enabled(bool enabled) {
    if (enabled && getenv("WWHD_RES_SCALE")) return;
    gfx::set_native_resolution_enabled(enabled);
    if (!getenv("WWHD_RES_SCALE")) set("nativeResolution", enabled ? "1" : "0");
}
bool set_custom_resolution(unsigned width, unsigned height) {
    if (!gfx::set_custom_resolution((float)width, (float)height)) return false;
    if (!getenv("WWHD_RES_SCALE")) set("nativeResolution", "0");
    if (!env_override({"WWHD_RES_SCALE", "WWHD_ASPECT"})) {
        set("customWidth", std::to_string(width));
        set("customHeight", std::to_string(height));
    }
    return true;
}
void clear_custom_resolution() {
    gfx::clear_custom_resolution();
    if (!getenv("WWHD_RES_SCALE")) set("nativeResolution", "0");
    if (!env_override({"WWHD_RES_SCALE", "WWHD_ASPECT"})) {
        set("customWidth", "0");
        set("customHeight", "0");
    }
}
int tv_fill_mode() { return gfx::display_tv_fill_mode(); }
void set_tv_fill_mode(int mode) {
    mode = mode == gfx::kTvCrop ? gfx::kTvCrop : gfx::kTvFit;
    gfx::display_set_tv_fill_mode(mode);
    set("tvFillMode", std::to_string(mode));
}
void graphics_changed() {
    save_if_unoverridden("aniso", {"WWHD_ANISO"}, render::aniso() ? "1" : "0");
    save_if_unoverridden("fxaa", {"WWHD_FXAA"}, render::fxaa() ? "1" : "0");
    save_if_unoverridden("fps60", {"WWHD_INTERP", "WWHD_INTERP_FPS"}, std::to_string(interp::mode()));
    save_if_unoverridden("interpFps", {"WWHD_INTERP_FPS"}, std::to_string(interp::fps()));
    const int aspect_mode = aspect::mode();
    if (aspect_mode != aspect::kCustom)
        save_if_unoverridden("aspect", {"WWHD_ASPECT"}, std::to_string(aspect_mode));
    save_if_unoverridden("bloom", {"WWHD_BLOOM"}, std::to_string(look::bloom()));
    save_if_unoverridden("hud", {"WWHD_HUD"}, look::hud() ? "1" : "0");
    save_if_unoverridden("fog", {"WWHD_FOG"}, std::to_string(look::fog()));
    save_if_unoverridden("sharpness", {"WWHD_SHARPNESS"}, std::to_string(look::sharpness()));
#ifdef WWHD_HAS_VULKAN
    save_if_unoverridden("vkPresentMode", {"WWHD_VK_PRESENT_MODE"}, std::to_string(gfxvk::present_mode()));
#endif
}
int scale_filter() { return gfx::g_filter; }
void set_scale_filter(int f) {
    gfx::g_filter = std::clamp(f, 0, 2);
    save_if_unoverridden("scaleFilter", {"WWHD_SCALE_FILTER"}, std::to_string(gfx::g_filter.load()));
}
bool scale_filter_available() { return true; }
bool fullscreen() { return true; }
void set_fullscreen(bool) {}
int drc_modes() { return gfx::kDrcModeCount; }
bool drc_mode_offered(int m) { return gfx::drc_mode_offered(m); }
int drc_mode() { return gfx::g_mode; }
void set_drc_mode(int m) {
    if (!drc_mode_offered(m)) return;
    gfx::display_set_mode(m);
    save_if_unoverridden("drcMode", {"WWHD_DRC_MODE"}, gfx::kModeNames[m]);
}
int pip_corner() { return gfx::g_corner; }
void set_pip_corner(int c) {
    c = std::clamp(c, 0, 3);
    gfx::g_corner = c;
    save_if_unoverridden("pipCorner", {"WWHD_DRC_PIP"}, gfx::kCornerNames[c]);
}
float pip_size() { return gfx::g_pip_size; }
void set_pip_size(float s) {
    s = std::clamp(s, 0.1f, 0.5f);
    gfx::g_pip_size = s;
    save_if_unoverridden("pipSize", {"WWHD_DRC_PIP"}, std::to_string(s));
}
float pip_opacity() { return gfx::g_pip_opacity; }
void set_pip_opacity(float o) {
    o = std::clamp(o, 0.2f, 1.f);
    gfx::g_pip_opacity = o;
    save_if_unoverridden("pipOpacity", {"WWHD_DRC_PIP"}, std::to_string(o));
}
bool drc_available() { return true; }
bool drc_shown() { return gfx::drc_screen_shown(false); }
void show_drc(bool on) {
    gfx::display_show_drc(on);
    set("drcShown", on ? "1" : "0");
}
void set_pro_controller(bool on) { input::set_pro_controller(on); }
const char* name() { return "UIKit"; }
void set_clipboard(const std::string& t) { UIPasteboard.generalPasteboard.string = @(t.c_str()); }
void run_posted() {}
static bool saved_uint(const char* key, unsigned& out) {
    std::string value;
    if (!get(key, value) || value.empty()) return false;
    errno = 0;
    char* end = nullptr;
    unsigned long n = std::strtoul(value.c_str(), &end, 10);
    if (errno || end == value.c_str() || *end || n > UINT_MAX) return false;
    out = (unsigned)n;
    return true;
}
static bool saved_float(const char* key, float& out) {
    std::string value;
    if (!get(key, value) || value.empty()) return false;
    errno = 0;
    char* end = nullptr;
    const float n = std::strtof(value.c_str(), &end);
    if (errno || end == value.c_str() || *end || !std::isfinite(n) || n < 0.5f || n > 4.0f) return false;
    out = n;
    return true;
}
static bool saved_float_range(const char* key, float minimum, float maximum, float& out) {
    std::string value;
    if (!get(key, value) || value.empty()) return false;
    errno = 0;
    char* end = nullptr;
    const float n = std::strtof(value.c_str(), &end);
    if (errno || end == value.c_str() || *end || !std::isfinite(n) || n < minimum || n > maximum) return false;
    out = n;
    return true;
}
static bool saved_int(const char* key, int minimum, int maximum, int& out) {
    std::string value;
    if (!get(key, value) || value.empty()) return false;
    errno = 0;
    char* end = nullptr;
    const long n = std::strtol(value.c_str(), &end, 10);
    if (errno || end == value.c_str() || *end || n < minimum || n > maximum) return false;
    out = (int)n;
    return true;
}
static bool saved_bool(const char* key, bool& out) {
    int n;
    if (!saved_int(key, 0, 1, n)) return false;
    out = n != 0;
    return true;
}
void load_saved_options() {
    std::string fill;
    gfx::display_set_tv_fill_mode(get("tvFillMode", fill) && fill == std::to_string(gfx::kTvCrop) ? gfx::kTvCrop : gfx::kTvFit);
    if (!getenv("WWHD_RES_SCALE")) {
        float scale = 1.0f;
        if (saved_float("resScale", scale)) render::set_res_scale(scale);
    }
    int option = 0;
    bool enabled;
    if (!getenv("WWHD_ANISO") && saved_bool("aniso", enabled)) {
        render::set_aniso(enabled);
    }
    if (!getenv("WWHD_FXAA") && saved_bool("fxaa", enabled)) {
        render::set_fxaa(enabled);
    }
    if (!getenv("WWHD_INTERP_FPS") && saved_int("interpFps", 60, 240, option) &&
        (option == 60 || option == 120 || option == 240)) interp::set_fps(option);
    if (!env_override({"WWHD_INTERP", "WWHD_INTERP_FPS"}) && saved_bool("fps60", enabled)) interp::set_mode(enabled ? 1 : 0);
    if (!getenv("WWHD_ASPECT") && saved_int("aspect", aspect::kOriginal, aspect::k32x9, option)) aspect::set_mode(option);
    if (!getenv("WWHD_BLOOM") && saved_int("bloom", look::kBloomOriginal, look::kBloomModes - 1, option))
        look::set_bloom(option);
    if (!getenv("WWHD_HUD") && saved_bool("hud", enabled)) look::set_hud(enabled);
    if (!getenv("WWHD_FOG") && saved_int("fog", look::kBloomOriginal, look::kBloomModes - 1, option))
        look::set_fog(option);
    if (!getenv("WWHD_SHARPNESS") && saved_int("sharpness", look::kSharpOriginal, look::kSharpest, option))
        look::set_sharpness(option);
#ifdef WWHD_HAS_VULKAN
    if (!getenv("WWHD_VK_PRESENT_MODE") && saved_int("vkPresentMode", 0, 2, option)) gfxvk::set_present_mode(option);
#endif
    std::string spatial;
    if (!getenv("WWHD_METALFX_SPATIAL") && get("metalFxSpatial", spatial) && (spatial == "0" || spatial == "1"))
        gfx::set_spatial_upscale_enabled(spatial == "1");
    bool native = false;
    const bool use_native = !getenv("WWHD_RES_SCALE") && saved_bool("nativeResolution", native) &&
                            gfx::native_resolution::restore_mode(native, getenv("WWHD_RES_SCALE") != nullptr);
    unsigned width = 0, height = 0;
    // Apply custom dimensions last so they stay active and retain the saved scale as their fallback.
    if (!use_native && !env_override({"WWHD_RES_SCALE", "WWHD_ASPECT"}) && saved_uint("customWidth", width) &&
        saved_uint("customHeight", height) && width && height)
        gfx::set_custom_resolution((float)width, (float)height);
    if (use_native) gfx::set_native_resolution_enabled(true);
    std::string saved_mode;
    if (get("drcMode", saved_mode)) {
        const int mode = gfx::find_name(gfx::kModeNames, gfx::kDrcModeCount, saved_mode.c_str(), -1);
        if (drc_mode_offered(mode)) gfx::display_set_mode(mode);
    }
    if (get("pipCorner", saved_mode)) {
        const int corner = gfx::find_name(gfx::kCornerNames, 4, saved_mode.c_str(), -1);
        if (corner >= 0) gfx::g_corner = corner;
    }
    float display_value;
    if (saved_float_range("pipSize", 0.1f, 0.5f, display_value)) gfx::g_pip_size = display_value;
    if (saved_float_range("pipOpacity", 0.2f, 1.0f, display_value)) gfx::g_pip_opacity = display_value;
    if (!getenv("WWHD_SCALE_FILTER") && saved_int("scaleFilter", gfx::kSmooth, gfx::kInteger, option))
        gfx::g_filter = option;
    gfx::display_env_overrides();  // saved values first; debug overrides win for this launch
    bool shown;
    if (saved_bool("drcShown", shown)) gfx::display_show_drc(shown);
}
void toggle_drc() { show_drc(!drc_shown()); }
void drc_window_closed() {}
void tv_fullscreen_changed() {}

void edit_custom_resolution(unsigned width, unsigned height) {
    post([width, height] {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"自定义渲染尺寸"
            message:@"请输入整数像素宽度和高度。此设置会按相同比例重新布局游戏画面和 HUD，不改变游戏逻辑尺寸。"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
            field.placeholder = @"宽度（像素）";
            field.keyboardType = UIKeyboardTypeNumberPad;
            field.text = [NSString stringWithFormat:@"%u", width ? width : 1920];
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
            field.placeholder = @"高度（像素）";
            field.keyboardType = UIKeyboardTypeNumberPad;
            field.text = [NSString stringWithFormat:@"%u", height ? height : 1080];
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"应用" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
            auto parse = [](NSString* text, unsigned& out) {
                const char* raw = text.UTF8String;
                if (!raw || !*raw) return false;
                errno = 0;
                char* end = nullptr;
                unsigned long n = std::strtoul(raw, &end, 10);
                if (errno || end == raw || *end || n == 0 || n > UINT_MAX) return false;
                out = (unsigned)n;
                return true;
            };
            unsigned w = 0, h = 0;
            if (!parse(alert.textFields[0].text, w) || !parse(alert.textFields[1].text, h)) {
                UIAlertController* error = [UIAlertController alertControllerWithTitle:@"尺寸无效"
                    message:@"请输入 1–4096 之间的整数像素宽度和高度。" preferredStyle:UIAlertControllerStyleAlert];
                [error addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [g_window.rootViewController presentViewController:error animated:YES completion:nil];
                return;
            }
            if (!set_custom_resolution(w, h)) {
                const gfx::CustomResolutionStatus status = gfx::custom_resolution_status();
                const char* reason = "尺寸不受支持。";
                switch (status.error) {
                case gfx::CustomResolutionError::InvalidDimensions: reason = "尺寸或比例超出支持范围。"; break;
                case gfx::CustomResolutionError::PixelLimit: reason = "总像素数超过 8,294,400。"; break;
                case gfx::CustomResolutionError::DeviceUnavailable: reason = "Metal 设备尚未准备好。"; break;
                case gfx::CustomResolutionError::TextureProbeFailed: reason = "设备无法为此尺寸分配纹理。"; break;
                case gfx::CustomResolutionError::AllocationFallback: reason = "渲染目标分配失败，已回退到之前的倍率。"; break;
                case gfx::CustomResolutionError::DimensionLimit: reason = "尺寸超过内部渲染上限。"; break;
                default: break;
                }
                UIAlertController* error = [UIAlertController alertControllerWithTitle:@"无法应用尺寸"
                    message:@(reason) preferredStyle:UIAlertControllerStyleAlert];
                [error addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [g_window.rootViewController presentViewController:error animated:YES completion:nil];
            }
        }]];
        [g_window.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}
}

@implementation TPMetalView
+ (Class)layerClass { return CAMetalLayer.class; }
- (void)layoutSubviews {
    [super layoutSubviews];
    self.contentScaleFactor = self.window.screen.scale ?: 2;
    const CGSize size = self.bounds.size;
    const CGFloat scale = self.contentScaleFactor;
    const BOOL changed = self.hasLayoutGeometry &&
        (!CGSizeEqualToSize(size, self.lastLayoutSize) || fabs(scale - self.lastLayoutScale) > 0.001);
    self.hasLayoutGeometry = YES;
    self.lastLayoutSize = size;
    self.lastLayoutScale = scale;
    if (changed && self.gamepadTouch) {
        input::set_touch(false, 0, 0);
        self.gamepadTouch = nil;
    }
    CAMetalLayer* layer = (CAMetalLayer*)self.layer;
    layer.contentsScale = self.contentScaleFactor;
    layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
}
- (void)sendTouches:(NSSet<UITouch*>*)touches ending:(BOOL)ending {
    for (UITouch* touch in touches) {
        CGPoint p = [touch locationInView:self];
        if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) continue;
        float nx = p.x / self.bounds.size.width, ny = p.y / self.bounds.size.height;
        if (overlay::captures()) {
            overlay::mouse_move(nx, ny);
            overlay::mouse_button(0, !ending);
        } else {
            float x = 0, y = 0;
            bool tracked = touch == self.gamepadTouch;
            if ((!self.gamepadTouch || tracked) && gfx::overlay_hit(nx, ny, &x, &y, tracked)) {
                if (!ending) self.gamepadTouch = touch;
                input::set_touch(!ending, x, y);
                gfx::display_touched();
            }
            if (ending && tracked) {
                input::set_touch(false, 0, 0);
                self.gamepadTouch = nil;
            }
        }
    }
}
- (void)touchesBegan:(NSSet<UITouch*>*)t withEvent:(UIEvent*)e { [self sendTouches:t ending:NO]; }
- (void)touchesMoved:(NSSet<UITouch*>*)t withEvent:(UIEvent*)e { [self sendTouches:t ending:NO]; }
- (void)touchesEnded:(NSSet<UITouch*>*)t withEvent:(UIEvent*)e { [self sendTouches:t ending:YES]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)t withEvent:(UIEvent*)e { [self sendTouches:t ending:YES]; }
@end

static bool supported_rpx(NSString* path) {
    FILE* file = fopen(path.fileSystemRepresentation, "rb");
    if (!file) return false;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[65536], digest[CC_SHA256_DIGEST_LENGTH];
    size_t n;
    while ((n = fread(buffer, 1, sizeof buffer, file))) CC_SHA256_Update(&context, buffer, (CC_LONG)n);
    bool ok = !ferror(file);
    fclose(file);
    CC_SHA256_Final(digest, &context);
    char hex[65];
    for (unsigned i = 0; i < sizeof digest; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return ok && !strcmp(hex, "28922198517578c9261ac0b0b04a586252033d3bbcf7980b79e37638775b12a9");
}

static NSString* state_sha256(NSString* path) {
    FILE* file = fopen(path.fileSystemRepresentation, "rb");
    if (!file) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[65536], digest[CC_SHA256_DIGEST_LENGTH];
    size_t n;
    while ((n = fread(buffer, 1, sizeof buffer, file))) CC_SHA256_Update(&context, buffer, (CC_LONG)n);
    const bool ok = !ferror(file);
    fclose(file);
    CC_SHA256_Final(digest, &context);
    if (!ok) return nil;
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (unsigned i = 0; i < sizeof digest; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return [NSString stringWithUTF8String:hex];
}

static bool state_acl_count(NSString* path, int* count) {
    acl_t acl = acl_get_file(path.fileSystemRepresentation, ACL_TYPE_EXTENDED);
    if (!acl) {
        if (errno == ENOENT) {
            struct stat info{};
            if (lstat(path.fileSystemRepresentation, &info) == 0) { *count = 0; return true; }
        }
        return false;
    }
    int entries = 0;
    acl_entry_t entry;
    int cursor = ACL_FIRST_ENTRY;
    for (;;) {
        int result = acl_get_entry(acl, cursor, &entry);
        if (result == 0) break;
        if (result < 0) { acl_free(acl); return false; }
        ++entries;
        cursor = ACL_NEXT_ENTRY;
    }
    acl_free(acl);
    *count = entries;
    return true;
}

static NSString* state_protection_class(NSDictionary* attributes) {
    id value = attributes[NSFileProtectionKey];
    return value ? [value description] : @"unset";
}

static bool state_same_protection(NSString* original, NSString* copy) {
    NSDictionary* original_attributes = [NSFileManager.defaultManager attributesOfItemAtPath:original error:nil];
    NSDictionary* copy_attributes = [NSFileManager.defaultManager attributesOfItemAtPath:copy error:nil];
    if (!original_attributes || !copy_attributes) return false;
    id original_class = original_attributes[NSFileProtectionKey];
    id copy_class = copy_attributes[NSFileProtectionKey];
    return (!original_class && !copy_class) || (original_class && copy_class && [original_class isEqual:copy_class]);
}

static NSDictionary* state_copy_attributes(NSDictionary* source, NSUInteger mode) {
    NSMutableDictionary* attributes = [NSMutableDictionary dictionaryWithObject:@(mode & 07777)
                                                                           forKey:NSFilePosixPermissions];
    id protection = source[NSFileProtectionKey];
    if (protection) attributes[NSFileProtectionKey] = protection;
    return attributes;
}

static bool state_path_type(NSString* path, mode_t type, struct stat* out) {
    struct stat info{};
    if (lstat(path.fileSystemRepresentation, &info) != 0 || (info.st_mode & S_IFMT) != type) return false;
    if (out) *out = info;
    return true;
}

static bool state_known_file(NSString* path, uint64_t size, NSString* expected_hash,
                             NSDictionary** attributes_out, struct stat* stat_out) {
    struct stat info{};
    if (!state_path_type(path, S_IFREG, &info) || (uint64_t)info.st_size != size || info.st_flags != UF_TRACKED) return false;
    int acl_count = 0;
    if (!state_acl_count(path, &acl_count) || acl_count != 0) return false;
    NSString* actual_hash = state_sha256(path);
    if (!actual_hash || ![actual_hash isEqualToString:expected_hash]) return false;
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attributes) return false;
    if (attributes_out) *attributes_out = attributes;
    if (stat_out) *stat_out = info;
    return true;
}

static bool repair_state_owner_mismatch_once(NSString* docs) {
    const char* requested = getenv("WWHD_TEST_REPAIR_STATE_OWNER_ONCE");
    if (!requested || strcmp(requested, "1") != 0) return true;
    if (!getenv("WWHD_NO_HOST_INPUT") || getenv("WWHD_MOD_MANAGER_DIR")) {
        fprintf(stderr, "[ios] state repair refused: requires no-host-input mode and default manager storage\n");
        return false;
    }
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* state = [docs stringByAppendingPathComponent:@"state"];
    NSString* cache = [state stringByAppendingPathComponent:@"Cache"];
    NSString* profile = [state stringByAppendingPathComponent:@"profiles.json"];
    NSString* marker = [cache stringByAppendingPathComponent:@"ACCEPTANCE_CLEANED.txt"];
    NSString* stage = [docs stringByAppendingPathComponent:@"state.owner-mismatch-stage-20261025"];
    NSString* backup = [docs stringByAppendingPathComponent:@"state.owner-mismatch-backup-20261025"];
    struct stat state_stat{};
    if (!state_path_type(state, S_IFDIR, &state_stat)) {
        fprintf(stderr, "[ios] state repair refused: existing state directory missing or not a directory\n");
        return false;
    }
    if (state_stat.st_flags != 0) {
        fprintf(stderr, "[ios] state repair refused: state directory has filesystem flags=%u\n", (unsigned)state_stat.st_flags);
        return false;
    }
    const int access_result = access(state.fileSystemRepresentation, W_OK | X_OK);
    const int access_errno = access_result == 0 ? 0 : errno;
    if (state_stat.st_uid == geteuid() && access_result == 0) {
        fprintf(stderr, "[ios] state repair skipped: current owner already has write and execute access\n");
        return true;
    }
    if (state_stat.st_uid == geteuid() || state_stat.st_gid != getegid() || access_result == 0 || access_errno != EACCES ||
        (state_stat.st_mode & 07777) != 0755) {
        fprintf(stderr, "[ios] state repair refused: owner/group/access/mode precondition changed\n");
        return false;
    }
    int state_acl = 0, cache_acl = 0;
    if (!state_acl_count(state, &state_acl) || state_acl != 0 || !state_path_type(cache, S_IFDIR, nullptr) ||
        !state_acl_count(cache, &cache_acl) || cache_acl != 0) {
        fprintf(stderr, "[ios] state repair refused: ACL metadata is present or unavailable\n");
        return false;
    }
    NSArray<NSString*>* root_entries = [[fm contentsOfDirectoryAtPath:state error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSString*>* cache_entries = [[fm contentsOfDirectoryAtPath:cache error:nil] sortedArrayUsingSelector:@selector(compare:)];
    if (![root_entries isEqualToArray:@[@"Cache", @"profiles.json"]] ||
        ![cache_entries isEqualToArray:@[@"ACCEPTANCE_CLEANED.txt"]]) {
        fprintf(stderr, "[ios] state repair refused: state contents no longer match the verified test-only inventory\n");
        return false;
    }
    NSDictionary* state_attributes = [fm attributesOfItemAtPath:state error:nil];
    NSDictionary* cache_attributes = [fm attributesOfItemAtPath:cache error:nil];
    NSDictionary* profile_attributes = nil;
    NSDictionary* marker_attributes = nil;
    struct stat cache_stat{}, profile_stat{}, marker_stat{};
    const bool cache_type_ok = state_path_type(cache, S_IFDIR, &cache_stat);
    const bool cache_flags_ok = cache_type_ok && cache_stat.st_flags == 0;
    const bool profile_type_ok = state_path_type(profile, S_IFREG, &profile_stat);
    const bool profile_size_ok = profile_type_ok && (uint64_t)profile_stat.st_size == 154;
    const bool profile_flags_ok = profile_type_ok && profile_stat.st_flags == UF_TRACKED;
    int profile_acl = -1;
    const bool profile_acl_readable = state_acl_count(profile, &profile_acl);
    const bool profile_hash_ok = [state_sha256(profile) isEqualToString:@"15a914e6a682d7ac2c10c295b0d1d3f718dded25d946cb5eebee2d90e600738d"];
    profile_attributes = [fm attributesOfItemAtPath:profile error:nil];
    const bool marker_type_ok = state_path_type(marker, S_IFREG, &marker_stat);
    const bool marker_size_ok = marker_type_ok && (uint64_t)marker_stat.st_size == 70;
    const bool marker_flags_ok = marker_type_ok && marker_stat.st_flags == UF_TRACKED;
    int marker_acl = -1;
    const bool marker_acl_readable = state_acl_count(marker, &marker_acl);
    const bool marker_hash_ok = [state_sha256(marker) isEqualToString:@"7d550d0a6b8a2e29ca874cb4292f53b7f13da85c05bf21292deea96d42dd58b7"];
    marker_attributes = [fm attributesOfItemAtPath:marker error:nil];
    const bool profile_valid = profile_type_ok && profile_size_ok && profile_flags_ok &&
        profile_acl_readable && profile_acl == 0 && profile_hash_ok && profile_attributes;
    const bool marker_valid = marker_type_ok && marker_size_ok && marker_flags_ok &&
        marker_acl_readable && marker_acl == 0 && marker_hash_ok && marker_attributes;
    if (!state_attributes || !cache_attributes || !cache_type_ok || !cache_flags_ok || !profile_valid || !marker_valid) {
        fprintf(stderr, "[ios] state repair preflight detail state-attrs=%d cache-attrs=%d cache-type=%d cache-flags=%u profile-type=%d profile-size=%d profile-flags=%u profile-acl-readable=%d profile-acl-count=%d profile-hash=%d profile-attrs=%d marker-type=%d marker-size=%d marker-flags=%u marker-acl-readable=%d marker-acl-count=%d marker-hash=%d marker-attrs=%d\n",
                !!state_attributes, !!cache_attributes, cache_type_ok, cache_type_ok ? (unsigned)cache_stat.st_flags : 0,
                profile_type_ok, profile_size_ok, profile_type_ok ? (unsigned)profile_stat.st_flags : 0,
                profile_acl_readable, profile_acl, profile_hash_ok, !!profile_attributes,
                marker_type_ok, marker_size_ok, marker_type_ok ? (unsigned)marker_stat.st_flags : 0,
                marker_acl_readable, marker_acl, marker_hash_ok, !!marker_attributes);
        fprintf(stderr, "[ios] state repair refused: verified profile/cache bytes, types, flags, or ACLs changed\n");
        return false;
    }
    fprintf(stderr, "[ios] state repair inventory verified files=2 bytes=224 ACLs=0 tracked-file-flags=0x40 preserved profile-protection=%s cache-protection=%s\n",
            state_protection_class(profile_attributes).UTF8String, state_protection_class(marker_attributes).UTF8String);
    if ([fm fileExistsAtPath:stage] || [fm fileExistsAtPath:backup]) {
        fprintf(stderr, "[ios] state repair refused: staging or backup name already exists\n");
        return false;
    }
    NSError* error = nil;
    if (![fm createDirectoryAtPath:stage withIntermediateDirectories:NO
                        attributes:state_copy_attributes(state_attributes, state_stat.st_mode) error:&error]) {
        fprintf(stderr, "[ios] state repair staging creation failed: %s\n",
                error.localizedDescription.UTF8String ?: "unavailable");
        return false;
    }
    NSString* staged_cache = [stage stringByAppendingPathComponent:@"Cache"];
    bool staged = [fm createDirectoryAtPath:staged_cache withIntermediateDirectories:NO
                                 attributes:state_copy_attributes(cache_attributes, cache_stat.st_mode) error:&error];
    NSData* profile_data = staged ? [NSData dataWithContentsOfFile:profile options:NSDataReadingMappedIfSafe error:&error] : nil;
    NSData* marker_data = staged ? [NSData dataWithContentsOfFile:marker options:NSDataReadingMappedIfSafe error:&error] : nil;
    if (staged && profile_data.length == 154 && marker_data.length == 70) {
        staged = [fm createFileAtPath:[stage stringByAppendingPathComponent:@"profiles.json"]
                              contents:profile_data attributes:state_copy_attributes(profile_attributes, profile_stat.st_mode)];
        staged = staged && [fm createFileAtPath:[staged_cache stringByAppendingPathComponent:@"ACCEPTANCE_CLEANED.txt"]
                                        contents:marker_data attributes:state_copy_attributes(marker_attributes, marker_stat.st_mode)];
    } else staged = false;
    NSString* staged_profile = [stage stringByAppendingPathComponent:@"profiles.json"];
    NSString* staged_marker = [staged_cache stringByAppendingPathComponent:@"ACCEPTANCE_CLEANED.txt"];
    if (staged && (lchflags(staged_profile.fileSystemRepresentation, profile_stat.st_flags) != 0 ||
                   lchflags(staged_marker.fileSystemRepresentation, marker_stat.st_flags) != 0))
        staged = false;
    struct stat stage_stat{}, staged_cache_stat{}, staged_profile_stat{}, staged_marker_stat{};
    int stage_acl = -1, staged_cache_acl = -1, staged_profile_acl = -1, staged_marker_acl = -1;
    const bool stage_valid = staged && state_path_type(stage, S_IFDIR, &stage_stat) && state_path_type(staged_cache, S_IFDIR, &staged_cache_stat) &&
        state_path_type(staged_profile, S_IFREG, &staged_profile_stat) && state_path_type(staged_marker, S_IFREG, &staged_marker_stat) &&
        stage_stat.st_uid == geteuid() && staged_cache_stat.st_uid == geteuid() && staged_profile_stat.st_uid == geteuid() && staged_marker_stat.st_uid == geteuid() &&
        stage_stat.st_gid == getegid() && staged_cache_stat.st_gid == getegid() && staged_profile_stat.st_gid == getegid() && staged_marker_stat.st_gid == getegid() &&
        (stage_stat.st_mode & 07777) == (state_stat.st_mode & 07777) && (staged_cache_stat.st_mode & 07777) == (cache_stat.st_mode & 07777) &&
        (staged_profile_stat.st_mode & 07777) == (profile_stat.st_mode & 07777) && (staged_marker_stat.st_mode & 07777) == (marker_stat.st_mode & 07777) &&
        state_acl_count(stage, &stage_acl) && stage_acl == 0 && state_acl_count(staged_cache, &staged_cache_acl) && staged_cache_acl == 0 &&
        state_acl_count(staged_profile, &staged_profile_acl) && staged_profile_acl == 0 && state_acl_count(staged_marker, &staged_marker_acl) && staged_marker_acl == 0 &&
        stage_stat.st_flags == 0 && staged_cache_stat.st_flags == 0 &&
        staged_profile_stat.st_flags == profile_stat.st_flags && staged_marker_stat.st_flags == marker_stat.st_flags &&
        state_same_protection(state, stage) && state_same_protection(cache, staged_cache) &&
        state_same_protection(profile, staged_profile) && state_same_protection(marker, staged_marker) &&
        [state_sha256(staged_profile) isEqualToString:@"15a914e6a682d7ac2c10c295b0d1d3f718dded25d946cb5eebee2d90e600738d"] &&
        [state_sha256(staged_marker) isEqualToString:@"7d550d0a6b8a2e29ca874cb4292f53b7f13da85c05bf21292deea96d42dd58b7"] &&
        access(stage.fileSystemRepresentation, W_OK | X_OK) == 0 && access(staged_cache.fileSystemRepresentation, W_OK | X_OK) == 0;
    if (!stage_valid) {
        fprintf(stderr, "[ios] state repair refused: staging owner/access/mode/ACL/protection/content verification failed; original untouched\n");
        [fm removeItemAtPath:stage error:nil];
        return false;
    }
    struct stat source_recheck{}, cache_recheck{}, profile_recheck{}, marker_recheck{};
    int source_acl_recheck = -1, cache_acl_recheck = -1;
    NSDictionary* unused_attributes = nil;
    NSArray<NSString*>* source_entries_recheck = [[fm contentsOfDirectoryAtPath:state error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSString*>* cache_entries_recheck = [[fm contentsOfDirectoryAtPath:cache error:nil] sortedArrayUsingSelector:@selector(compare:)];
    if (!state_path_type(state, S_IFDIR, &source_recheck) || source_recheck.st_uid == geteuid() ||
        source_recheck.st_uid != state_stat.st_uid || source_recheck.st_gid != state_stat.st_gid ||
        (source_recheck.st_mode & 07777) != (state_stat.st_mode & 07777) || source_recheck.st_flags != 0 ||
        ![source_entries_recheck isEqualToArray:@[@"Cache", @"profiles.json"]] ||
        ![cache_entries_recheck isEqualToArray:@[@"ACCEPTANCE_CLEANED.txt"]] ||
        !state_acl_count(state, &source_acl_recheck) || source_acl_recheck != 0 ||
        !state_path_type(cache, S_IFDIR, &cache_recheck) || cache_recheck.st_flags != cache_stat.st_flags ||
        cache_recheck.st_uid != cache_stat.st_uid || cache_recheck.st_gid != cache_stat.st_gid ||
        (cache_recheck.st_mode & 07777) != (cache_stat.st_mode & 07777) ||
        !state_acl_count(cache, &cache_acl_recheck) || cache_acl_recheck != 0 ||
        !state_known_file(profile, 154, @"15a914e6a682d7ac2c10c295b0d1d3f718dded25d946cb5eebee2d90e600738d", &unused_attributes, &profile_recheck) ||
        !state_known_file(marker, 70, @"7d550d0a6b8a2e29ca874cb4292f53b7f13da85c05bf21292deea96d42dd58b7", &unused_attributes, &marker_recheck) ||
        profile_recheck.st_uid != profile_stat.st_uid || profile_recheck.st_gid != profile_stat.st_gid ||
        (profile_recheck.st_mode & 07777) != (profile_stat.st_mode & 07777) || profile_recheck.st_flags != profile_stat.st_flags ||
        marker_recheck.st_uid != marker_stat.st_uid || marker_recheck.st_gid != marker_stat.st_gid ||
        (marker_recheck.st_mode & 07777) != (marker_stat.st_mode & 07777) || marker_recheck.st_flags != marker_stat.st_flags) {
        fprintf(stderr, "[ios] state repair refused: source changed during staging; original untouched\n");
        [fm removeItemAtPath:stage error:nil];
        return false;
    }
    error = nil;
    if (![fm moveItemAtPath:state toPath:backup error:&error]) {
        fprintf(stderr, "[ios] state repair could not preserve original as backup: %s\n",
                error.localizedDescription.UTF8String ?: "unavailable");
        [fm removeItemAtPath:stage error:nil];
        return false;
    }
    error = nil;
    if (![fm moveItemAtPath:stage toPath:state error:&error]) {
        NSError* rollback_error = nil;
        const bool rolled_back = [fm moveItemAtPath:backup toPath:state error:&rollback_error];
        fprintf(stderr, "[ios] state repair stage swap failed; rollback=%d error=%s\n", rolled_back,
                error.localizedDescription.UTF8String ?: "unavailable");
        if (!rolled_back) fprintf(stderr, "[ios] state repair rollback failed; original remains at state.owner-mismatch-backup-20261025\n");
        return false;
    }
    struct stat installed_state{}, installed_cache{}, installed_profile{}, installed_marker{};
    int installed_acl = -1, installed_cache_acl = -1;
    NSArray<NSString*>* installed_entries = [[fm contentsOfDirectoryAtPath:state error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSString*>* installed_cache_entries = [[fm contentsOfDirectoryAtPath:[state stringByAppendingPathComponent:@"Cache"] error:nil] sortedArrayUsingSelector:@selector(compare:)];
    const bool installed_children_valid = state_path_type([state stringByAppendingPathComponent:@"Cache"], S_IFDIR, &installed_cache) &&
        state_path_type([state stringByAppendingPathComponent:@"profiles.json"], S_IFREG, &installed_profile) &&
        state_path_type([state stringByAppendingPathComponent:@"Cache/ACCEPTANCE_CLEANED.txt"], S_IFREG, &installed_marker) &&
        installed_cache.st_uid == geteuid() && installed_profile.st_uid == geteuid() && installed_marker.st_uid == geteuid() &&
        installed_cache.st_gid == getegid() && installed_profile.st_gid == getegid() && installed_marker.st_gid == getegid() &&
        installed_cache.st_flags == 0 && installed_profile.st_flags == profile_stat.st_flags && installed_marker.st_flags == marker_stat.st_flags &&
        (installed_cache.st_mode & 07777) == (cache_stat.st_mode & 07777) &&
        (installed_profile.st_mode & 07777) == (profile_stat.st_mode & 07777) &&
        (installed_marker.st_mode & 07777) == (marker_stat.st_mode & 07777) &&
        [installed_entries isEqualToArray:@[@"Cache", @"profiles.json"]] &&
        [installed_cache_entries isEqualToArray:@[@"ACCEPTANCE_CLEANED.txt"]] &&
        state_acl_count([state stringByAppendingPathComponent:@"Cache"], &installed_cache_acl) && installed_cache_acl == 0 &&
        [state_sha256([state stringByAppendingPathComponent:@"profiles.json"]) isEqualToString:@"15a914e6a682d7ac2c10c295b0d1d3f718dded25d946cb5eebee2d90e600738d"] &&
        [state_sha256([state stringByAppendingPathComponent:@"Cache/ACCEPTANCE_CLEANED.txt"]) isEqualToString:@"7d550d0a6b8a2e29ca874cb4292f53b7f13da85c05bf21292deea96d42dd58b7"];
    const bool installed_valid = state_path_type(state, S_IFDIR, &installed_state) && installed_state.st_uid == geteuid() &&
        installed_state.st_gid == getegid() &&
        (installed_state.st_mode & 07777) == (state_stat.st_mode & 07777) && installed_state.st_flags == 0 &&
        state_acl_count(state, &installed_acl) && installed_acl == 0 && access(state.fileSystemRepresentation, W_OK | X_OK) == 0 &&
        installed_children_valid && state_same_protection(backup, state) &&
        state_same_protection([backup stringByAppendingPathComponent:@"Cache"], [state stringByAppendingPathComponent:@"Cache"]) &&
        state_same_protection([backup stringByAppendingPathComponent:@"profiles.json"], [state stringByAppendingPathComponent:@"profiles.json"]) &&
        state_same_protection([backup stringByAppendingPathComponent:@"Cache/ACCEPTANCE_CLEANED.txt"], [state stringByAppendingPathComponent:@"Cache/ACCEPTANCE_CLEANED.txt"]);
    if (!installed_valid) {
        NSError* move_new = nil;
        const bool saved_new = [fm moveItemAtPath:state toPath:stage error:&move_new];
        NSError* rollback_error = nil;
        const bool rolled_back = saved_new && [fm moveItemAtPath:backup toPath:state error:&rollback_error];
        fprintf(stderr, "[ios] state repair post-swap verification failed; rollback=%d; original backup retained if rollback failed\n", rolled_back);
        return false;
    }
    fprintf(stderr, "[ios] state repair succeeded: original retained at state.owner-mismatch-backup-20261025; files=2 bytes=224 hashes verified\n");
    return true;
}

int wwhd_runtime_main(int, char**);
@interface TPAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation TPAppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options {
    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* statePath = [docs stringByAppendingPathComponent:@"state"];
    for (NSString* folder in @[@"save", @"captures"])
        [fm createDirectoryAtPath:[docs stringByAppendingPathComponent:folder] withIntermediateDirectories:YES attributes:nil error:nil];
    chdir(docs.fileSystemRepresentation);
    setenv("WWHD_STATE_DIR", "state", 1);
    setenv("WWHD_SHADER_CACHE", "state/shaders.bin", 1);
    const char* repair_request = getenv("WWHD_TEST_REPAIR_STATE_OWNER_ONCE");
    const bool repair_requested = repair_request && std::string_view(repair_request) == "1";
    bool repair_ready = true;
    if (freopen("captures/ios-console.log", "a", stderr)) {
        setvbuf(stderr, nullptr, _IONBF, 0);
        repair_ready = repair_state_owner_mismatch_once(docs);
        if (!repair_requested || repair_ready)
            [fm createDirectoryAtPath:statePath withIntermediateDirectories:YES attributes:nil error:nil];
        else
            fprintf(stderr, "[ios] state repair failed; runtime startup will be blocked and state was not recreated\n");
        struct stat stateInfo{};
        if (lstat(statePath.fileSystemRepresentation, &stateInfo) != 0) {
            fprintf(stderr, "[ios] state directory stat failed errno=%d; no path fallback attempted\n", errno);
        } else if (!S_ISDIR(stateInfo.st_mode)) {
            fprintf(stderr, "[ios] state path is not a directory; left unchanged\n");
        } else {
            const NSUInteger mode = static_cast<NSUInteger>(stateInfo.st_mode & 07777);
            errno = 0;
            const int writeAccess = access(statePath.fileSystemRepresentation, W_OK | X_OK);
            const int writeAccessErrno = writeAccess == 0 ? 0 : errno;
            fprintf(stderr, "[ios] state directory mode=%04o owner-write=%d owner-match=%d group-match=%d write-execute-access=%d access-errno=%d flags=%u\n",
                    (unsigned)mode, !!(mode & S_IWUSR), stateInfo.st_uid == geteuid(), stateInfo.st_gid == getegid(),
                    writeAccess == 0, writeAccessErrno, (unsigned)stateInfo.st_flags);
            if (!repair_requested && !(mode & S_IWUSR)) {
                NSError* permissionError = nil;
                const NSUInteger repairedMode = mode | S_IWUSR;
                const bool changed = [fm setAttributes:@{NSFilePosixPermissions: @(repairedMode)}
                                             ofItemAtPath:statePath error:&permissionError];
                if (!changed) {
                    const char* error = permissionError ? permissionError.localizedDescription.UTF8String : nullptr;
                    fprintf(stderr, "[ios] state directory owner-write repair failed error=%s errno=%d; no path fallback or data replacement\n",
                            error ? error : "unavailable", errno);
                }
            }
            struct stat after{};
            if (lstat(statePath.fileSystemRepresentation, &after) != 0) {
                fprintf(stderr, "[ios] state directory post-check failed errno=%d\n", errno);
            } else if (!S_ISDIR(after.st_mode)) {
                fprintf(stderr, "[ios] state path changed type during permission check; left unchanged\n");
            } else {
                const NSUInteger finalMode = static_cast<NSUInteger>(after.st_mode & 07777);
                errno = 0;
                const int finalWriteAccess = access(statePath.fileSystemRepresentation, W_OK | X_OK);
                const int finalWriteErrno = finalWriteAccess == 0 ? 0 : errno;
                fprintf(stderr, "[ios] state directory post-check mode=%04o owner-write=%d owner-match=%d group-match=%d write-execute-access=%d access-errno=%d flags=%u\n",
                        (unsigned)finalMode, !!(finalMode & S_IWUSR), after.st_uid == geteuid(), after.st_gid == getegid(),
                        finalWriteAccess == 0, finalWriteErrno, (unsigned)after.st_flags);
                if (!repair_requested && !(finalMode & S_IWUSR))
                    fprintf(stderr, "[ios] state directory remains without owner-write; no path fallback or data replacement\n");
            }
        }
    } else if (repair_requested) {
        repair_ready = false;
        fprintf(stderr, "[ios] state repair failed: app console could not be opened; runtime startup will be blocked\n");
    }
    const bool state_repair_failed = repair_requested && !repair_ready;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    g_window = self.window;
    UIViewController* vc = [UIViewController new];
    g_canvas = [[TPMetalView alloc] initWithFrame:self.window.bounds];
    g_canvas.multipleTouchEnabled = YES;
    g_canvas.backgroundColor = UIColor.blackColor;
    vc.view = g_canvas;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (state_repair_failed) {
            UILabel* status = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds, 40, 60)];
            status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            status.numberOfLines = 0;
            status.textAlignment = NSTextAlignmentCenter;
            status.textColor = UIColor.whiteColor;
            status.text = @"State repair did not complete.\nThe game was not started.\nCheck Documents/captures/ios-console.log before trying again.";
            [vc.view addSubview:status];
            fprintf(stderr, "[ios] runtime startup blocked after requested state repair failure; no package import or game/save runtime started\n");
            return;
        }
        bool realCode = g_recomp_entry_point != 0;
        bool haveGame = [fm fileExistsAtPath:@"game/code/Zelda.rpx"];
        if (!realCode || !haveGame || !supported_rpx(@"game/code/Zelda.rpx")) {
            UILabel* status = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds, 40, 60)];
            status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            status.numberOfLines = 0;
            status.textAlignment = NSTextAlignmentCenter;
            status.textColor = UIColor.whiteColor;
            status.text = !realCode ? @"Twilight Princess HD\nRuntime build check — no game code.\nThis build cannot play the game."
                : !haveGame ? @"Copy the verified USA Rev 2 / v81 game folder to Documents/game, then relaunch."
                : @"Unsupported Zelda.rpx. Use the unmodified USA Rev 2 / v81 base game.";
            [vc.view addSubview:status];
            return;
        }
        NSError* error = nil;
        [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:&error];
        [AVAudioSession.sharedInstance setActive:YES error:&error];
        if (error) LOG("[ios] audio session: %s", error.localizedDescription.UTF8String);
        app.idleTimerDisabled = YES;
        char name[] = "tphd", gameOption[] = "--game", game[] = "game", saveOption[] = "--save", save[] = "save";
        char* argv[] = {name, gameOption, game, saveOption, save, nullptr};
        wwhd_runtime_main(5, argv);
        g_running = true;
        ios::install_controls(vc);
    });
    return YES;
}
- (void)applicationWillResignActive:(UIApplication*)app { ios::set_active(false); app.idleTimerDisabled = NO; }
- (void)applicationDidBecomeActive:(UIApplication*)app { ios::set_active(true); app.idleTimerDisabled = g_running; }
@end

int main(int argc, char** argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TPAppDelegate.class)); }
}
