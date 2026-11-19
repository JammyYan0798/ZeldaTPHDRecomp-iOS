#pragma once

#include <array>
#include <cstdint>
#include <mutex>
#include <vector>

namespace padscore {

// KPAD connect callbacks are delivered by the guest-safe periodic alarm dispatcher. The callback
// executes after this lock is released, so it may register, replace, or clear callbacks itself.
class ConnectCallbacks {
public:
    struct Event {
        uint32_t channel;
        uint32_t callback;
        int32_t status;
        uint64_t generation;
    };

    uint32_t set(uint32_t channel, uint32_t callback) {
        if (channel >= slots_.size()) return 0;
        std::lock_guard<std::mutex> lock(mutex_);
        Slot& slot = slots_[channel];
        const uint32_t previous = slot.callback;
        slot.callback = callback;
        slot.initialized = false;
        ++slot.generation;
        return previous;
    }

    void reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        for (Slot& slot : slots_) {
            slot.callback = 0;
            slot.initialized = false;
            slot.connected = false;
            ++slot.generation;
        }
    }

    bool has_callbacks() const {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const Slot& slot : slots_)
            if (slot.callback) return true;
        return false;
    }

    template <typename Dispatch>
    void poll(bool pro_controller, Dispatch&& dispatch) {
        std::vector<Event> events;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (polling_) return;  // A guest callback can re-enter KPAD or its registration HLEs.
            polling_ = true;
            for (uint32_t channel = 0; channel < slots_.size(); ++channel) {
                Slot& slot = slots_[channel];
                const bool connected = channel == 0 && pro_controller;
                bool notify = false;
                int32_t status = -1;
                if (!slot.initialized) {
                    slot.initialized = true;
                    slot.connected = connected;
                    notify = connected;
                    status = 0;
                } else if (slot.connected != connected) {
                    slot.connected = connected;
                    notify = true;
                    status = connected ? 0 : -1;
                }
                if (notify && slot.callback)
                    events.push_back({channel, slot.callback, status, slot.generation});
            }
        }

        struct FinishPoll {
            ConnectCallbacks& owner;
            ~FinishPoll() {
                std::lock_guard<std::mutex> lock(owner.mutex_);
                owner.polling_ = false;
            }
        } finish{*this};

        for (const Event& event : events) {
            bool current;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                const Slot& slot = slots_[event.channel];
                current = slot.callback == event.callback && slot.generation == event.generation;
            }
            if (current) dispatch(event);
        }
    }

private:
    struct Slot {
        uint32_t callback = 0;
        uint64_t generation = 0;
        bool initialized = false;
        bool connected = false;
    };

    mutable std::mutex mutex_;
    std::array<Slot, 4> slots_{};
    bool polling_ = false;
};

}  // namespace padscore
