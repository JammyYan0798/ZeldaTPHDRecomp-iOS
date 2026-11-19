#pragma once
#include <cstdint>

namespace threads {
// Schedule through the save-state-safe guest alarm thread. key is an opaque, unique runtime token.
void schedule_periodic_callback(uint32_t key, uint64_t period, uint32_t callback);
void cancel_periodic_callback(uint32_t key);
}  // namespace threads
