#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Hashing

/// FNV-1a offset basis. Callers seed a rolling hash with this value.
extern const uint64_t pm_hash_fnv1a64_basis;

/// Fold one 64-bit value into a rolling FNV-1a hash.
uint64_t pm_hash_fnv1a64_value(uint64_t hash, uint64_t value);

/// Fold `length` bytes into a rolling FNV-1a hash, one byte per round.
uint64_t pm_hash_fnv1a64_bytes(
    uint64_t hash,
    const uint8_t *bytes,
    int32_t length
);

/// Hash a normalized string into the identity space used by the mix ranker.
/// Empty input hashes to 0, and non-empty input never does, so 0 doubles as
/// the "absent artist / album" sentinel.
uint64_t pm_text_identity_hash(const uint8_t *bytes, int32_t length);

#pragma mark - Text folding and search

/// `pm_text_fold_utf8` could not fold the input: it holds code points outside
/// the ASCII + Cyrillic fast path. Callers must fall back to the platform
/// folder, which stays authoritative for every other script.
#define PM_TEXT_FOLD_UNSUPPORTED (-1)
/// The destination buffer was too small for the folded result.
#define PM_TEXT_FOLD_OVERFLOW (-2)

/// Case- and diacritic-fold UTF-8 text the way
/// `folding(options: [.caseInsensitive, .diacriticInsensitive]).lowercased()`
/// does, for ASCII and Cyrillic only. Uppercase ASCII and Cyrillic letters are
/// lowercased, `ё` folds to `е` and `й` folds to `и` — matching the decompose
/// then strip-marks behaviour of the platform folder.
///
/// Returns the folded byte count, `PM_TEXT_FOLD_UNSUPPORTED` when the input
/// leaves the fast path, or `PM_TEXT_FOLD_OVERFLOW` when `out_capacity` is too
/// small. Folded output is never longer than the input.
int32_t pm_text_fold_utf8(
    const uint8_t *input,
    int32_t length,
    uint8_t *out,
    int32_t out_capacity
);

/// Byte offset of the first occurrence of `needle` in `haystack`, or -1.
/// An empty needle reports -1 so callers match `String.contains("")`, which is
/// false on Foundation.
int32_t pm_text_find(
    const uint8_t *haystack,
    int32_t haystack_length,
    const uint8_t *needle,
    int32_t needle_length
);

/// Fold + trim ASCII whitespace the way `MixQueueRanker.normalized` does for
/// artist / album identity. Uses the same ASCII + Cyrillic fast path as
/// `pm_text_fold_utf8`; callers fall back to Foundation for other scripts.
int32_t pm_text_normalize_identity(
    const uint8_t *input,
    int32_t length,
    uint8_t *out,
    int32_t out_capacity
);

#pragma mark - Artwork tint

typedef struct PMArtworkTint {
    float red;
    float green;
    float blue;
} PMArtworkTint;

/// Saturation-weighted dominant colour of premultiplied-last RGBA bytes.
/// Returns false when `length` is invalid or every pixel is transparent.
bool pm_artwork_extract_tint_rgba(
    const uint8_t *rgba,
    int32_t length,
    PMArtworkTint *out
);

#pragma mark - Mix queue ranking

/// Rank the upcoming queue toward the seed track.
#define PM_MIX_MODE_CLOSER_TO_SEED 1
/// Rank the upcoming queue toward unfamiliar artists.
#define PM_MIX_MODE_MORE_NOVEL 2

/// One ranking candidate, reduced to identity hashes so the selection loop
/// never touches string storage. A hash of 0 means the normalized value was
/// empty, which the scoring rules treat as "no artist" / "no album".
typedef struct PMMixCandidate {
    uint64_t artist_hash;
    uint64_t album_hash;
} PMMixCandidate;

/// Inputs that stay constant while one queue is ranked.
typedef struct PMMixRankContext {
    int32_t mode;
    uint64_t seed_artist_hash;
    uint64_t seed_album_hash;
    /// Artist hashes pulled from listening history, sorted ascending so the
    /// scoring loop can binary search instead of rehashing strings.
    const uint64_t *history_hashes;
    int32_t history_count;
} PMMixRankContext;

/// Index of the highest scoring candidate, replacing the Swift greedy loop
/// that re-folded every artist and album string on every pick.
///
/// `jitter` holds one pre-drawn random tie-breaker per candidate, already
/// scaled to the mode's range, so the caller keeps ownership of the random
/// sequence and ranking stays reproducible. `recent_hashes` is ordered oldest
/// to newest and drives the artist spacing penalty.
///
/// Returns 0 for an empty or malformed candidate list, matching the Swift
/// loop's initial best index.
int32_t pm_mix_select_best(
    const PMMixCandidate *candidates,
    const double *jitter,
    int32_t count,
    const PMMixRankContext *context,
    const uint64_t *recent_hashes,
    int32_t recent_count
);

/// Score a single candidate. Exposed for tests and for callers that need the
/// value rather than the winner; `pm_mix_select_best` uses the same rules.
double pm_mix_score_candidate(
    PMMixCandidate candidate,
    double jitter,
    const PMMixRankContext *context,
    const uint64_t *recent_hashes,
    int32_t recent_count
);

#pragma mark - Buffer health estimator

/// Number of recent throughput samples the ring buffer keeps. Fixed at
/// compile time so `pm_buffer_health` never allocates.
#define PM_BUFFER_HEALTH_WINDOW_CAPACITY 32

/// Sentinel `pm_buffer_health_predicted_underrun` returns when the buffer is
/// not draining: throughput at or above `play_rate`, a non-positive
/// `play_rate`, or no sample observed yet. Large enough that callers can
/// treat it as "no imminent underrun" without a separate boolean.
#define PM_BUFFER_HEALTH_UNDERRUN_NONE 1.0e9

/// Fixed-memory rolling estimator over `AVPlayerItem.loadedTimeRanges`
/// samples, sampled from the ~2 Hz periodic time observer. Every field is
/// POD and the sample window is a ring buffer sized by
/// `PM_BUFFER_HEALTH_WINDOW_CAPACITY`, so observing a sample never
/// allocates.
///
/// `throughput` is expressed as a multiple of normal playback speed: `1.0`
/// means the loaded range is neither growing nor shrinking (download rate
/// equals a normal-speed playback's consumption rate), `> 1.0` means the
/// buffer is filling, and `< 1.0` (down to `0`) means it is draining. This
/// assumes playback proceeds at its usual pace between samples; a paused or
/// fast-forwarded item between two `observe` calls will skew the reading
/// until fresh samples flush it out of the window.
typedef struct PMBufferHealthState {
    double rate_samples[PM_BUFFER_HEALTH_WINDOW_CAPACITY];
    double rate_sum;
    int32_t rate_count;
    int32_t next_index;
    double previous_timestamp;
    double previous_loaded_ahead;
    double latest_loaded_ahead;
    bool has_previous;
} pm_buffer_health;

/// Clear every sample and forget the previous tick, as if newly constructed.
/// Call this when a new item loads so a track switch does not blend its
/// history with the last track's throughput.
void pm_buffer_health_reset(pm_buffer_health *state);

/// Record one `loadedTimeRanges` sample. `now_seconds` should be a
/// monotonic wall clock (e.g. `CACurrentMediaTime()`); `loaded_ahead_seconds`
/// is how far the loaded range extends past the current playback position.
///
/// The first call after a reset only seeds the previous-sample state — a
/// rate needs a time delta, so it takes two calls to produce one. Ticks
/// whose `now_seconds` is not strictly after the previous tick (clock jump,
/// duplicate tick) are dropped rather than divided by a near-zero interval,
/// though the latest-observed value they carry still updates
/// `pm_buffer_health_predicted_underrun`'s input.
void pm_buffer_health_observe(
    pm_buffer_health *state,
    double now_seconds,
    double loaded_ahead_seconds
);

/// Smoothed loaded-seconds-per-wall-second over the current window. Returns
/// `1.0` (steady) before any rate sample exists, i.e. before the second
/// `pm_buffer_health_observe` call since the last reset.
double pm_buffer_health_throughput(const pm_buffer_health *state);

/// Seconds until the buffer is predicted to run dry at `play_rate` (`1.0`
/// for normal speed), extrapolating the current smoothed throughput from
/// the most recently observed loaded-ahead value. Returns
/// `PM_BUFFER_HEALTH_UNDERRUN_NONE` when throughput is at or above
/// `play_rate`, when `play_rate` is not positive, or when no sample has
/// been observed yet.
double pm_buffer_health_predicted_underrun(
    const pm_buffer_health *state,
    double play_rate
);

#ifdef __cplusplus
}
#endif
