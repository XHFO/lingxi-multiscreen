#pragma once
#include <stdbool.h>
#include <stdint.h>

// A short control lease blocks stale in-flight uploads, not standalone sources.
// If the Mac crashes, the block expires; without a new software frame the device
// still stays local. This state is never written to NVS.
static inline bool c6_simulation_active(int64_t until, int64_t now) {
    return until > now;
}
static inline int64_t c6_simulation_deadline(bool enabled, int64_t now) {
    return enabled ? now + INT64_C(45000000) : 0;
}
