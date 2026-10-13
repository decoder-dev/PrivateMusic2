#pragma once

// Implemented in Rust: native/pm-native/src/offline.rs.

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pm_eviction_candidate {
    /// Seconds (any consistent reference); older values are evicted first.
    double last_played_at;
    int64_t byte_count;
    /// Automatic-cache entry that is not the track playing right now.
    bool evictable;
} pm_eviction_candidate;

/// Chooses evictable candidates, least recently played first, until at
/// least `required_bytes` would be released. Ties keep input order. Writes
/// candidate indices to `out_indices` in eviction order and returns how many
/// were chosen (0 when `required_bytes` is not positive).
int32_t pm_offline_select_evictions(
    const pm_eviction_candidate *candidates,
    int32_t count,
    int64_t required_bytes,
    int32_t *out_indices,
    int32_t out_capacity
);

#ifdef __cplusplus
}
#endif
