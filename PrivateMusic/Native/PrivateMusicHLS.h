#pragma once

// Implemented in Rust: native/pm-native/src/hls.rs (HLS playlist parsing).
// Results point into the UTF-8 text that was passed in, as byte offsets.

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PM_HLS_OK 0
#define PM_HLS_INVALID_ENCRYPTION_KEY 1
#define PM_HLS_UNSUPPORTED_ENCRYPTION_METHOD 2
#define PM_HLS_INVALID_INITIALIZATION_SECTION 3
#define PM_HLS_INVALID_BYTE_RANGE 4
#define PM_HLS_ENCRYPTED_INIT_NEEDS_IV 5
#define PM_HLS_TOO_MANY_SEGMENTS 6
#define PM_HLS_INVALID_TEXT (-1)

#define PM_HLS_CHOOSE_MEDIA_PLAYLIST 0
#define PM_HLS_CHOOSE_FOUND 1
#define PM_HLS_CHOOSE_NONE 2

/// Byte range inside the parsed text; `length < 0` means absent.
typedef struct pm_hls_slice {
    int32_t offset;
    int32_t length;
} pm_hls_slice;

typedef struct pm_hls_key {
    pm_hls_slice uri;
    bool has_iv;
    uint8_t iv[16];
} pm_hls_key;

typedef struct pm_hls_map {
    pm_hls_slice uri;
    bool has_range;
    int64_t range_length;
    bool has_range_offset;
    int64_t range_offset;
    /// Index into the key table, or -1.
    int32_t key_index;
} pm_hls_map;

typedef struct pm_hls_segment {
    pm_hls_slice uri;
    bool has_range;
    int64_t range_length;
    bool has_range_offset;
    int64_t range_offset;
    int32_t key_index;
    int32_t map_index;
    bool discontinuity;
} pm_hls_segment;

typedef struct pm_hls_media_info {
    int32_t code;
    int64_t media_sequence;
    int32_t segment_count;
    int32_t key_count;
    int32_t map_count;
    /// For PM_HLS_UNSUPPORTED_ENCRYPTION_METHOD: the method text.
    pm_hls_slice detail;
} pm_hls_media_info;

/// Picks the audio playlist URI out of a master playlist. Returns
/// `PM_HLS_CHOOSE_*` (or `PM_HLS_INVALID_TEXT`); `uri` is set when found.
int32_t pm_hls_choose_audio(const uint8_t *text, int32_t length, pm_hls_slice *uri);

/// Parses a media playlist. Tables are filled up to their capacities while
/// `info` always reports the full counts, so a first call with null tables
/// sizes the second. Returns `info->code`.
int32_t pm_hls_parse_media(
    const uint8_t *text,
    int32_t length,
    int32_t max_segments,
    pm_hls_media_info *info,
    pm_hls_segment *segments,
    int32_t segment_capacity,
    pm_hls_key *keys,
    int32_t key_capacity,
    pm_hls_map *maps,
    int32_t map_capacity
);

#ifdef __cplusplus
}
#endif
