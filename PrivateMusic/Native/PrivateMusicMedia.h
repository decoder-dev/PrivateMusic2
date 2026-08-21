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

#pragma mark - CMAF fragment extract

#define PM_CMAF_OK 0
#define PM_CMAF_MISSING_MOOF 1
#define PM_CMAF_MISSING_TFHD 2
#define PM_CMAF_TRACK_MISMATCH 3
#define PM_CMAF_MISSING_SIZE 4
#define PM_CMAF_SAMPLE_OUTSIDE 5
#define PM_CMAF_MISSING_MDAT 6
#define PM_CMAF_TRUNCATED 7
#define PM_CMAF_OVERFLOW 8
#define PM_CMAF_MISSING_FTYP 9
#define PM_CMAF_MISSING_MOOV 10
#define PM_CMAF_NO_AUDIO_TRACK 11
#define PM_CMAF_UNSUPPORTED_CODEC 12
#define PM_CMAF_INVALID_INIT 13
#define PM_CMAF_SAMPLE_LIMIT 65536

typedef struct PMCMAFSample {
    int32_t offset;
    int32_t size;
    int64_t decode_time;
    int64_t presentation_time;
    int64_t duration;
    bool is_sync;
} pm_cmaf_sample;

typedef struct PMCMAFStatus {
    int32_t code;
    uint32_t found_track_id;
} pm_cmaf_status;

/// One `moof`/`mdat` fragment → sample table into `mdat`. Never allocates.
/// `out` may be NULL to count. `decode_time` / `has_decode_time` are inout
/// running DTS when `tfdt` is omitted.
int32_t pm_cmaf_extract_fragment(
    const uint8_t *data,
    int32_t length,
    uint32_t track_id,
    uint32_t default_duration,
    bool has_default_duration,
    uint32_t default_size,
    bool has_default_size,
    uint32_t default_flags,
    bool has_default_flags,
    int64_t *decode_time,
    bool *has_decode_time,
    pm_cmaf_sample *out,
    int32_t out_capacity,
    pm_cmaf_status *status
);

typedef struct PMCMAFInitialization {
    uint32_t track_id;
    uint32_t timescale;
    uint32_t sample_rate;
    uint32_t channel_count;
    uint32_t codec_fourcc;
    uint32_t default_sample_duration;
    uint32_t default_sample_size;
    uint32_t default_sample_flags;
    bool has_default_duration;
    bool has_default_size;
    bool has_default_flags;
    /// Byte offsets into the original buffer. Negative when absent.
    int32_t esds_offset;
    int32_t esds_length;
    int32_t asc_offset;
    int32_t asc_length;
} pm_cmaf_init;

/// Parse `ftyp` + `moov` (audio `trak`, `stsd`/`esds`, `trex`). Never allocates.
/// Offsets in `out` are relative to `data`. Returns 1 on success, 0 on failure.
int32_t pm_cmaf_parse_initialization(
    const uint8_t *data,
    int32_t length,
    pm_cmaf_init *out,
    pm_cmaf_status *status
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

#pragma mark - HLS AES-128 CBC

#define PM_AES128_KEY_BYTES 16
#define PM_AES128_IV_BYTES 16
#define PM_AES128_BLOCK_BYTES 16

#define PM_AES128_OK 0
#define PM_AES128_INVALID_ARGUMENT (-1)
#define PM_AES128_DECRYPT_FAILED (-2)
#define PM_AES128_OUTPUT_TOO_SMALL (-3)

/// Decrypt AES-128-CBC with PKCS#7 padding (RFC 8216 HLS segments).
/// `out_capacity` must be at least `ciphertext_length + PM_AES128_BLOCK_BYTES`.
/// On success writes the plaintext length to `out_length`.
int32_t pm_aes128_cbc_decrypt(
    const uint8_t *ciphertext,
    int32_t ciphertext_length,
    const uint8_t *key,
    const uint8_t *iv,
    uint8_t *out,
    int32_t out_capacity,
    int32_t *out_length
);

#ifdef __cplusplus
}
#endif
