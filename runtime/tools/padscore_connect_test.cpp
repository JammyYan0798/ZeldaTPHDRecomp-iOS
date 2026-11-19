// Standalone bootstrap tests for KPAD connection events; no KPADReadEx call is made here.
#include "../src/hle/padscore_connect.h"

#include <cstdio>
#include <thread>
#include <vector>

using padscore::ConnectCallbacks;

static int g_fail = 0, g_pass = 0;
#define CHECK(x)                                                                                                    \
    do {                                                                                                            \
        if (x) g_pass++;                                                                                            \
        else { g_fail++; fprintf(stderr, "%s:%d: FAILED: %s\n", __FILE__, __LINE__, #x); }                       \
    } while (0)

int main() {
    ConnectCallbacks callbacks;
    std::vector<ConnectCallbacks::Event> events;
    auto collect = [&](const ConnectCallbacks::Event& event) { events.push_back(event); };
    auto guest_tick = [&](bool pro_mode) { callbacks.poll(pro_mode, collect); };

    CHECK(!callbacks.has_callbacks());
    CHECK(callbacks.set(0, 0x1000) == 0);
    CHECK(callbacks.has_callbacks());
    guest_tick(false);  // First periodic tick: disconnected is not a disconnect edge.
    CHECK(events.empty());
    guest_tick(true);   // A tick can report initial connection without any KPADReadEx call.
    CHECK(events.size() == 1 && events.back().channel == 0 && events.back().status == 0 &&
          events.back().callback == 0x1000);
    guest_tick(true);
    CHECK(events.size() == 1);
    guest_tick(false);
    CHECK(events.size() == 2 && events.back().status == -1);
    guest_tick(true);
    CHECK(events.size() == 3 && events.back().status == 0);

    CHECK(callbacks.set(0, 0x2000) == 0x1000);  // Replacement returns the old callback.
    guest_tick(true);                             // Re-registering while connected gets current state.
    CHECK(events.size() == 4 && events.back().callback == 0x2000 && events.back().status == 0);
    CHECK(callbacks.set(0, 0) == 0x2000);         // Null callback cancels it.
    CHECK(!callbacks.has_callbacks());
    guest_tick(false);
    CHECK(events.size() == 4);
    CHECK(callbacks.set(4, 0x3000) == 0);         // Out-of-range channels are ignored.

    callbacks.reset();
    CHECK(!callbacks.has_callbacks());
    for (uint32_t channel = 1; channel < 4; ++channel)
        CHECK(callbacks.set(channel, 0x4000 + channel) == 0);
    guest_tick(true);  // Pro mode only exposes the logical controller on channel 0.
    CHECK(events.size() == 4);

    callbacks.reset();
    CHECK(callbacks.set(0, 0x5000) == 0);
    int nested_calls = 0;
    callbacks.poll(true, [&](const ConnectCallbacks::Event& event) {
        CHECK(event.channel == 0 && event.callback == 0x5000 && event.status == 0);
        callbacks.poll(true, [&](const ConnectCallbacks::Event&) { ++nested_calls; });
        CHECK(callbacks.set(0, 0x6000) == 0x5000);  // Reentrant replacement does not deadlock.
    });
    CHECK(nested_calls == 0);
    callbacks.poll(true, collect);
    CHECK(events.back().callback == 0x6000 && events.back().status == 0);

    callbacks.reset();
    CHECK(callbacks.set(0, 0x7000) == 0);
    const std::thread::id caller = std::this_thread::get_id();
    std::thread::id dispatch_thread;
    std::thread worker([&] {
        callbacks.poll(true, [&](const ConnectCallbacks::Event&) { dispatch_thread = std::this_thread::get_id(); });
    });
    worker.join();
    CHECK(dispatch_thread != caller);  // Dispatch runs on its caller, never by hopping to a UI thread.

    fprintf(stderr, "padscore_connect_test: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
