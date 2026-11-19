#pragma once

#include <algorithm>
#include <cstdint>

namespace interp::detail {

// J2DPane::draw can visit one pane more than once in a logic pass. A single
// snapshot is safe to blend only when that pane was drawn exactly once.
struct PaneDrawRecord {
    uint64_t logic_pass = UINT64_MAX;
    uint64_t record_pass = UINT64_MAX;
    bool repeated = false;
    uint32_t matrix[12] = {};
    uint8_t alpha = 0;

    bool record(uint64_t logic, uint64_t step, const uint32_t current[12], uint8_t current_alpha) {
        if (logic_pass == logic) {
            repeated = true;
            return false;
        }
        logic_pass = logic;
        record_pass = step;
        repeated = false;
        std::copy(current, current + 12, matrix);
        alpha = current_alpha;
        return true;
    }

    bool can_blend(uint64_t step) const { return record_pass == step && !repeated; }
};

}  // namespace interp::detail
