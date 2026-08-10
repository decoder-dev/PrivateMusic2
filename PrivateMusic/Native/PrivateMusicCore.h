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

#ifdef __cplusplus
}
#endif
