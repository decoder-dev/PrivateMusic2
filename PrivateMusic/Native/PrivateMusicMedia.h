#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - MPEG-TS

#define PM_MPEGTS_KIND_NONE 0
#define PM_MPEGTS_KIND_ADTS 1
#define PM_MPEGTS_KIND_MP3 2

/// Detect 188/192/204-byte packets. Returns 0 when the buffer is not TS.
int32_t pm_mpegts_packet_size(const uint8_t *data, int32_t length);

/// Payload of one TS packet. `payload_offset` is relative to `packet`.
bool pm_mpegts_parse_packet(
    const uint8_t *packet,
    int32_t packet_size,
    int32_t *pid,
    bool *unit_start,
    int32_t *payload_offset,
    int32_t *payload_length
);

/// PMT PID from a PAT payload, or -1.
int32_t pm_mpegts_parse_pat(const uint8_t *payload, int32_t length);

bool pm_mpegts_parse_pmt(
    const uint8_t *payload,
    int32_t length,
    int32_t *audio_pid,
    uint8_t *stream_type
);

#define PM_MPEGTS_PES_UNBOUNDED (-1)

/// Maps one TS payload onto an elementary slice. `remaining` is inout:
/// `PM_MPEGTS_PES_UNBOUNDED` or bytes still owed from a length-prefixed PES.
bool pm_mpegts_pes_slice(
    const uint8_t *payload,
    int32_t payload_length,
    bool unit_start,
    int32_t *remaining,
    int32_t *out_offset,
    int32_t *out_length
);

/// Demux elementary audio into `out`. `scratch` holds PES reassembly and
/// must be at least `length` bytes. Returns `PM_MPEGTS_KIND_*`; 0 means
/// leave the original bytes alone. Never allocates.
int32_t pm_mpegts_extract_audio(
    const uint8_t *data,
    int32_t length,
    uint8_t *out,
    int32_t out_capacity,
    uint8_t *scratch,
    int32_t scratch_capacity,
    int32_t *out_length
);

#pragma mark - ISO BMFF

#define PM_ISO_OK 0
#define PM_ISO_TRUNCATED 1
#define PM_ISO_INVALID 2
#define PM_ISO_WALK_LIMIT 4096

typedef struct PMISOBox {
    uint32_t type;
    int32_t start;
    int32_t size;
    int32_t header_size;
} pm_iso_box;

typedef struct PMISOStatus {
    int32_t code;
    int32_t expected;
    int32_t available;
} pm_iso_status;

uint32_t pm_iso_fourcc(const char *type);

/// Walk boxes in `[start, end)`. Stops after `PM_ISO_WALK_LIMIT` boxes.
/// Returns the number of boxes found. `out` may be NULL to count only.
int32_t pm_iso_walk(
    const uint8_t *data,
    int32_t length,
    int32_t start,
    int32_t end,
    pm_iso_box *out,
    int32_t out_capacity,
    pm_iso_status *status
);

/// Top-level presence check used by HLS container detection.
bool pm_iso_contains_types(
    const uint8_t *data,
    int32_t length,
    const uint32_t *types,
    int32_t type_count
);

#pragma mark - VK stream unmask

#define PM_VK_UNMASK_NOT_MASKED 0
#define PM_VK_UNMASK_FAILED (-1)
#define PM_VK_UNMASK_OVERFLOW (-2)

/// Unmask an `audio_api_unavailable` URL. Returns the unmasked UTF-8 length,
/// `PM_VK_UNMASK_NOT_MASKED` when the marker is absent (caller keeps the
/// original URL), or a negative error.
int32_t pm_vk_unmask(
    const uint8_t *raw,
    int32_t raw_length,
    int32_t user_id,
    uint8_t *out,
    int32_t out_capacity
);

#pragma mark - Buffer loaded-ahead fold

/// Max of `end_seconds[i] - position_seconds` over finite samples. Empty
/// or fully non-finite input returns 0.
double pm_buffer_max_loaded_ahead(
    double position_seconds,
    const double *end_seconds,
    int32_t count
);

#ifdef __cplusplus
}
#endif
