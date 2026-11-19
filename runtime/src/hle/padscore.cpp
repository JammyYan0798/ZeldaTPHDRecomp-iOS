// padscore: Wii Remote / Pro Controller (WPAD, KPAD). Only a Pro Controller on channel 0 exists,
// and only while the keyboard/host controllers are set to act as one (Input menu). Struct layouts
// and constants follow Cemu's padscore.
#include "../crashrec.h"
#include "../runtime.h"
#include "../threads_alarm.h"
#include "../input.h"
#include "padscore_connect.h"
#include "../motion/motion.h"
#include "../rumble.h"
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>

namespace {
constexpr int32_t kWpadErrNone = 0, kWpadErrNoController = -1;
constexpr int32_t kKpadErrNone = 0, kKpadErrNoController = -2;
constexpr uint8_t kDevURCC = 31, kDevNone = 253, kFormatURCC = 22;

bool connected(uint32_t chan) { return chan == 0 && input::pro_controller(); }
padscore::ConnectCallbacks g_connect_callbacks;
std::mutex g_connect_schedule_mutex;
uint32_t g_connect_poll_alarm = 0, g_connect_poll_callback = 0;
bool g_connect_poll_scheduled = false;
std::atomic<unsigned> g_pro_trace_registrations{0}, g_pro_trace_events{0}, g_pro_trace_probes{0}, g_pro_trace_reads{0};

bool pro_connection_trace_enabled() {
    static const bool enabled = [] {
        const char* value = getenv("WWHD_TEST_PRO_CONNECTION_TRACE");
        return value && !strcmp(value, "1");
    }();
    return enabled;
}

bool pro_connection_trace_slot(std::atomic<unsigned>& counter, unsigned limit) {
    return pro_connection_trace_enabled() && counter.fetch_add(1, std::memory_order_relaxed) < limit;
}

void poll_connect_callbacks(Cpu* c) {
    g_connect_callbacks.poll(input::pro_controller(), [c](const padscore::ConnectCallbacks::Event& event) {
        TRACE("[pad] connection callback chan=%u type=%s status=%d callback=%08X", event.channel,
              event.status == kWpadErrNone ? "URCC" : "none", event.status, event.callback);
        if (pro_connection_trace_slot(g_pro_trace_events, 8))
            LOG("[pro-connection] notify chan=%u type=%s status=%d mode=%s", event.channel,
                event.status == kWpadErrNone ? "URCC" : "none", event.status,
                input::pro_controller() ? "Pro" : "GamePad");
        guest_call(c, event.callback, {event.channel, (uint32_t)event.status});
    });
}

void connect_poll_alarm(Cpu* c) { poll_connect_callbacks(c); }

void update_connect_poll() {
    std::lock_guard<std::mutex> lock(g_connect_schedule_mutex);
    if (g_connect_callbacks.has_callbacks()) {
        if (!g_connect_poll_scheduled && g_connect_poll_alarm && g_connect_poll_callback) {
            threads::schedule_periodic_callback(g_connect_poll_alarm, timebase::kTicksPerSec / 200,
                                                g_connect_poll_callback);
            g_connect_poll_scheduled = true;
        }
    } else if (g_connect_poll_scheduled) {
        threads::cancel_periodic_callback(g_connect_poll_alarm);
        g_connect_poll_scheduled = false;
    }
}

// VPAD button bits (input::PadState) -> Pro Controller (URCC) bits
uint32_t pro_buttons(uint32_t v) {
    static const uint32_t map[][2] = {
        {input::kUp, 0x1},     {input::kLeft, 0x2},    {input::kZR, 0x4},     {input::kX, 0x8},
        {input::kA, 0x10},     {input::kY, 0x20},      {input::kB, 0x40},     {input::kZL, 0x80},
        {input::kR, 0x200},    {input::kPlus, 0x400},  {input::kHome, 0x800}, {input::kMinus, 0x1000},
        {input::kL, 0x2000},   {input::kDown, 0x4000}, {input::kRight, 0x8000},
        {input::kStickR, 0x10000}, {input::kStickL, 0x20000},
    };
    uint32_t out = 0;
    for (auto& m : map)
        if (v & m[0]) out |= m[1];
    return out;
}
}  // namespace

namespace padscore {
void init() {
    // Register the host poll wrapper before guest startup. Alarm records use this stable dispatcher
    // address; it only forwards events to callbacks the game actually registered.
    g_connect_poll_alarm = mem::host_alloc(4, 4);
    g_connect_poll_callback = dispatch::register_host(connect_poll_alarm, "KPADConnectPoll");
}
}  // namespace padscore

HLE(padscore, KPADInit) {}
HLE(padscore, KPADInitEx) {}
HLE(padscore, KPADShutdown) {
    g_connect_callbacks.reset();
    update_connect_poll();
}
HLE(padscore, KPADEnableDPD) {}
HLE(padscore, KPADDisableDPD) {}
HLE(padscore, KPADEnableMpls) {}
HLE(padscore, KPADDisableMpls) {}
// Setter returns the previous callback; notifications run from the guest-safe alarm dispatcher.
HLE(padscore, KPADSetConnectCallback) {
    const uint32_t chan = arg(c, 0), callback = arg(c, 1);
    const uint32_t previous = g_connect_callbacks.set(chan, callback);
    TRACE("[pad] KPADSetConnectCallback(%u, %08X) -> %08X", chan, callback, previous);
    if (pro_connection_trace_slot(g_pro_trace_registrations, 4))
        LOG("[pro-connection] register chan=%u callback=%08X previous=%08X mode=%s", chan, callback, previous,
            input::pro_controller() ? "Pro" : "GamePad");
    update_connect_poll();
    ret(c, previous);
}
HLE(padscore, KPADGetMplsWorkSize) { ret(c, 0x5FE0); }
HLE(padscore, KPADSetMplsWorkarea) {}
HLE(padscore, WPADEnableURCC) {}
HLE(padscore, WPADEnableWiiRemote) {}
HLE(padscore, WPADDisconnect) {}
// The Pro Controller motor: cmd 0 stops it, 1 runs it until the game stops it. The Pro
// Controller is only connected while the keyboard/controllers act as one (see connected).
HLE(padscore, WPADControlMotor) {
    uint32_t chan = arg(c, 0), cmd = arg(c, 1);
    if (connected(chan)) {
        TRACE("[pad] WPADControlMotor(%u, %u) -> %s", chan, cmd, cmd ? "rumble" : "stop");
        rumble::pro_motor(chan, cmd != 0);
    }
    ret(c, (uint32_t)kWpadErrNone);
}
HLE(padscore, WPADGetBatteryLevel) { ret(c, 4); }  // full
HLE(padscore, WPADCanSendStreamData) { ret(c, 0); }
HLE(padscore, WPADSendStreamData) { ret(c, (uint32_t)kWpadErrNoController); }
HLE(padscore, WPADControlSpeaker) { ret(c, (uint32_t)kWpadErrNoController); }

HLE(padscore, WPADProbe) {
    // (chan, uint32* type) -> WPAD error
    uint32_t chan = arg(c, 0), type = arg(c, 1);
    bool on = connected(chan);
    TRACE("[pad] WPADProbe(%u) -> %s", chan, on ? "pro" : "none");
    const uint32_t dev_type = on ? kDevURCC : kDevNone;
    const int32_t status = on ? kWpadErrNone : kWpadErrNoController;
    if (type) st32(type, dev_type);
    if (pro_connection_trace_slot(g_pro_trace_probes, 8))
        LOG("[pro-connection] probe chan=%u type=%u status=%d mode=%s", chan, dev_type, status,
            input::pro_controller() ? "Pro" : "GamePad");
    ret(c, (uint32_t)status);
}

HLE(padscore, KPADReadEx) {
    // (chan, KPADStatus* buf, count, int32* err) -> samples written
    uint32_t chan = arg(c, 0), st = arg(c, 1), count = arg(c, 2), err = arg(c, 3);
    TRACE("[pad] KPADReadEx(%u, %08X, %u) connected=%d", chan, st, count, connected(chan));
    if (!connected(chan) || !st || (int32_t)count <= 0) {
        if (err) st32(err, (uint32_t)(connected(chan) ? kKpadErrNone : kKpadErrNoController));
        if (pro_connection_trace_slot(g_pro_trace_reads, 8))
            LOG("[pro-connection] read chan=%u type=%s status=%d samples=0 hold=00000000 mode=%s", chan,
                connected(chan) ? "URCC" : "none", connected(chan) ? kKpadErrNone : kKpadErrNoController,
                input::pro_controller() ? "Pro" : "GamePad");
        ret(c, 0);
        return;
    }
    static uint32_t last = 0;
    input::PadState p = crashrec::read(1);  // crash recovery records/replays it
    motion::right_stick(p.rx, p.ry);  // the Pro Controller's stick decides gyro use too (motion.h)
    uint32_t hold = pro_buttons(p.buttons);
    memset(mem::ptr(st), 0, 0xF0);
    st8(st + 0x5C, kDevURCC);     // devType
    st8(st + 0x5D, 0);            // wpadErr
    st8(st + 0x5F, kFormatURCC);  // data_format
    st32(st + 0x60, hold);                // ex_status.uc.hold
    st32(st + 0x64, hold & ~last);        // trig
    st32(st + 0x68, last & ~hold);        // release
    last = hold;
    stf32(st + 0x6C, p.lx); stf32(st + 0x70, p.ly);  // lstick
    stf32(st + 0x74, p.rx); stf32(st + 0x78, p.ry);  // rstick
    st32(st + 0x7C, 1);                   // charge
    st32(st + 0x80, 1);                   // cable
    if (err) st32(err, kKpadErrNone);
    if (pro_connection_trace_slot(g_pro_trace_reads, 8))
        LOG("[pro-connection] read chan=%u type=URCC status=0 samples=1 hold=%08X mode=%s", chan, hold,
            input::pro_controller() ? "Pro" : "GamePad");
    ret(c, 1);
}
