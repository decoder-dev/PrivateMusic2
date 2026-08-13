#include "PrivateMusicMedia.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

#pragma mark - MPEG-TS helpers

static bool pm_mpegts_looks_adts(const uint8_t *data, int32_t length) {
    if (data == NULL || length < 2) {
        return false;
    }
    return data[0] == 0xFF && (data[1] & 0xF6) == 0xF0;
}

static bool pm_mpegts_looks_mp3(const uint8_t *data, int32_t length) {
    if (data == NULL || length < 3) {
        return false;
    }
    if (data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33) {
        return true;
    }
    if (data[0] != 0xFF) {
        return false;
    }
    const int version_bits = (data[1] >> 3) & 0x03;
    const int layer_bits = (data[1] >> 1) & 0x03;
    if (version_bits == 1 || layer_bits == 0) {
        return false;
    }
    return (data[1] & 0xE0) == 0xE0;
}

static int32_t pm_mpegts_infer_kind(const uint8_t *data, int32_t length) {
    if (pm_mpegts_looks_adts(data, length)) {
        return PM_MPEGTS_KIND_ADTS;
    }
    if (pm_mpegts_looks_mp3(data, length)) {
        return PM_MPEGTS_KIND_MP3;
    }
    return PM_MPEGTS_KIND_NONE;
}

static int32_t pm_mpegts_kind_for_stream_type(uint8_t stream_type) {
    switch (stream_type) {
        case 0x0F:
            return PM_MPEGTS_KIND_ADTS;
        case 0x03:
        case 0x04:
            return PM_MPEGTS_KIND_MP3;
        default:
            return PM_MPEGTS_KIND_NONE;
    }
}

int32_t pm_mpegts_packet_size(const uint8_t *data, int32_t length) {
    if (data == NULL || length <= 0) {
        return 0;
    }
    const int32_t sizes[3] = {188, 192, 204};
    for (int size_index = 0; size_index < 3; size_index++) {
        const int32_t size = sizes[size_index];
        int32_t syncs = 0;
        int32_t offset = 0;
        while (offset + size <= length) {
            if (data[offset] != 0x47) {
                break;
            }
            syncs += 1;
            if (syncs >= 3) {
                return size;
            }
            offset += size;
        }
        if (syncs >= 2 && offset >= length) {
            return size;
        }
    }
    return 0;
}

bool pm_mpegts_parse_packet(
    const uint8_t *packet,
    int32_t packet_size,
    int32_t *pid,
    bool *unit_start,
    int32_t *payload_offset,
    int32_t *payload_length
) {
    if (packet == NULL || packet_size < 4 || packet[0] != 0x47) {
        return false;
    }
    const int32_t parsed_pid = ((packet[1] & 0x1F) << 8) | packet[2];
    const bool parsed_start = (packet[1] & 0x40) != 0;
    const int adaptation = (packet[3] >> 4) & 0x03;
    int32_t offset = 4;
    if (adaptation == 2 || adaptation == 3) {
        if (offset >= packet_size) {
            return false;
        }
        offset += 1 + (int32_t)packet[offset];
    }
    if (adaptation != 1 && adaptation != 3) {
        return false;
    }
    if (offset >= packet_size) {
        return false;
    }
    if (pid != NULL) {
        *pid = parsed_pid;
    }
    if (unit_start != NULL) {
        *unit_start = parsed_start;
    }
    if (payload_offset != NULL) {
        *payload_offset = offset;
    }
    if (payload_length != NULL) {
        *payload_length = packet_size - offset;
    }
    return true;
}

static const uint8_t *pm_mpegts_psi_section(
    const uint8_t *payload,
    int32_t length,
    int32_t *section_length
) {
    if (payload == NULL || length <= 0) {
        return NULL;
    }
    const int32_t pointer = payload[0];
    const int32_t start = 1 + pointer;
    if (start >= length) {
        return NULL;
    }
    if (section_length != NULL) {
        *section_length = length - start;
    }
    return payload + start;
}

int32_t pm_mpegts_parse_pat(
    const uint8_t *payload,
    int32_t length
) {
    int32_t section_length = 0;
    const uint8_t *section = pm_mpegts_psi_section(
        payload,
        length,
        &section_length
    );
    if (section == NULL || section_length < 8 || section[0] != 0x00) {
        return -1;
    }
    const int32_t declared = ((section[1] & 0x0F) << 8) | section[2];
    const int32_t section_end = 3 + declared;
    if (section_length < section_end || section_end < 12) {
        return -1;
    }
    int32_t offset = 8;
    const int32_t end = section_end - 4;
    while (offset + 4 <= end) {
        const int32_t program_number = (section[offset] << 8)
            | section[offset + 1];
        const int32_t pid = ((section[offset + 2] & 0x1F) << 8)
            | section[offset + 3];
        offset += 4;
        if (program_number != 0) {
            return pid;
        }
    }
    return -1;
}

bool pm_mpegts_parse_pmt(
    const uint8_t *payload,
    int32_t length,
    int32_t *audio_pid,
    uint8_t *stream_type
) {
    int32_t section_length = 0;
    const uint8_t *section = pm_mpegts_psi_section(
        payload,
        length,
        &section_length
    );
    if (section == NULL || section_length < 12 || section[0] != 0x02) {
        return false;
    }
    const int32_t declared = ((section[1] & 0x0F) << 8) | section[2];
    const int32_t section_end = 3 + declared;
    if (section_length < section_end || section_end < 16) {
        return false;
    }
    const int32_t program_info_length = ((section[10] & 0x0F) << 8)
        | section[11];
    int32_t offset = 12 + program_info_length;
    const int32_t end = section_end - 4;
    bool have_preferred = false;
    int32_t preferred_pid = 0;
    uint8_t preferred_type = 0;
    while (offset + 5 <= end) {
        const uint8_t type = section[offset];
        const int32_t elementary_pid = ((section[offset + 1] & 0x1F) << 8)
            | section[offset + 2];
        const int32_t es_info_length = ((section[offset + 3] & 0x0F) << 8)
            | section[offset + 4];
        offset += 5 + es_info_length;
        const int32_t kind = pm_mpegts_kind_for_stream_type(type);
        if (kind == PM_MPEGTS_KIND_NONE) {
            continue;
        }
        if (kind == PM_MPEGTS_KIND_ADTS) {
            if (audio_pid != NULL) {
                *audio_pid = elementary_pid;
            }
            if (stream_type != NULL) {
                *stream_type = type;
            }
            return true;
        }
        if (!have_preferred) {
            have_preferred = true;
            preferred_pid = elementary_pid;
            preferred_type = type;
        }
    }
    if (!have_preferred) {
        return false;
    }
    if (audio_pid != NULL) {
        *audio_pid = preferred_pid;
    }
    if (stream_type != NULL) {
        *stream_type = preferred_type;
    }
    return true;
}

bool pm_mpegts_pes_slice(
    const uint8_t *payload,
    int32_t payload_length,
    bool unit_start,
    int32_t *remaining,
    int32_t *out_offset,
    int32_t *out_length
) {
    if (payload == NULL || remaining == NULL || payload_length < 0) {
        return false;
    }
    int32_t start = 0;
    if (unit_start) {
        if (payload_length < 9
            || payload[0] != 0
            || payload[1] != 0
            || payload[2] != 1) {
            *remaining = PM_MPEGTS_PES_UNBOUNDED;
            return false;
        }
        const int32_t packet_length = (payload[4] << 8) | payload[5];
        const int32_t header_length = payload[8];
        const int32_t payload_start = 9 + header_length;
        if (payload_start > payload_length) {
            *remaining = PM_MPEGTS_PES_UNBOUNDED;
            return false;
        }
        *remaining = packet_length == 0
            ? PM_MPEGTS_PES_UNBOUNDED
            : packet_length - 3 - header_length;
        if (*remaining < 0) {
            *remaining = 0;
        }
        start = payload_start;
    } else if (*remaining == 0) {
        return false;
    }
    const int32_t available = payload_length - start;
    if (available <= 0) {
        return false;
    }
    int32_t count = available;
    if (*remaining != PM_MPEGTS_PES_UNBOUNDED && *remaining < count) {
        count = *remaining;
    }
    if (out_offset != NULL) {
        *out_offset = start;
    }
    if (out_length != NULL) {
        *out_length = count;
    }
    if (*remaining != PM_MPEGTS_PES_UNBOUNDED) {
        *remaining -= count;
        if (*remaining < 0) {
            *remaining = 0;
        }
    }
    return count > 0;
}

static int32_t pm_mpegts_find_pes(const uint8_t *data, int32_t length) {
    if (data == NULL || length < 4) {
        return -1;
    }
    for (int32_t index = 0; index + 3 < length; index++) {
        if (data[index] == 0x00
            && data[index + 1] == 0x00
            && data[index + 2] == 0x01) {
            return index;
        }
    }
    return -1;
}

static void pm_mpegts_consume(uint8_t *buffer, int32_t *length, int32_t count) {
    if (buffer == NULL || length == NULL || count <= 0) {
        return;
    }
    if (count >= *length) {
        *length = 0;
        return;
    }
    memmove(buffer, buffer + count, (size_t)(*length - count));
    *length -= count;
}

/// Returns consumed bytes, 0 when the caller should stop draining, -1 when
/// more payload is required.
static int32_t pm_mpegts_drain_pes(
    uint8_t *buffer,
    int32_t *buffer_length,
    uint8_t *elementary,
    int32_t elementary_capacity,
    int32_t *elementary_length,
    bool audio_only,
    bool allow_partial
) {
    if (buffer == NULL || buffer_length == NULL) {
        return 0;
    }
    const int32_t start = pm_mpegts_find_pes(buffer, *buffer_length);
    if (start < 0) {
        if (*buffer_length > 10000) {
            pm_mpegts_consume(buffer, buffer_length, *buffer_length - 3);
        }
        return 0;
    }
    if (start > 0) {
        pm_mpegts_consume(buffer, buffer_length, start);
    }
    if (*buffer_length < 9) {
        return allow_partial ? 0 : -1;
    }
    const uint8_t stream_id = buffer[3];
    if (audio_only && (stream_id < 0xC0 || stream_id > 0xDF)) {
        pm_mpegts_consume(buffer, buffer_length, 4);
        return 4;
    }
    const int32_t pes_packet_length = (buffer[4] << 8) | buffer[5];
    const int32_t header_data_length = buffer[8];
    const int32_t payload_start = 9 + header_data_length;
    if (*buffer_length < payload_start) {
        return allow_partial ? 0 : -1;
    }
    int32_t packet_end;
    if (pes_packet_length == 0) {
        if (!allow_partial) {
            return -1;
        }
        packet_end = *buffer_length;
    } else {
        packet_end = 6 + pes_packet_length;
        if (*buffer_length < packet_end && !allow_partial) {
            return -1;
        }
    }
    const int32_t end = packet_end < *buffer_length ? packet_end : *buffer_length;
    if (payload_start < end
        && elementary != NULL
        && elementary_length != NULL) {
        const int32_t copy = end - payload_start;
        if (*elementary_length >= 0
            && copy > 0
            && *elementary_length + copy <= elementary_capacity) {
            memcpy(
                elementary + *elementary_length,
                buffer + payload_start,
                (size_t)copy
            );
            *elementary_length += copy;
        }
    }
    pm_mpegts_consume(buffer, buffer_length, end);
    return end;
}

static void pm_mpegts_append_and_drain(
    uint8_t *pes,
    int32_t *pes_length,
    int32_t pes_capacity,
    const uint8_t *payload,
    int32_t payload_length,
    uint8_t *elementary,
    int32_t elementary_capacity,
    int32_t *elementary_length,
    bool audio_only
) {
    if (payload != NULL && payload_length > 0
        && *pes_length + payload_length <= pes_capacity) {
        memcpy(pes + *pes_length, payload, (size_t)payload_length);
        *pes_length += payload_length;
    }
    for (;;) {
        const int32_t consumed = pm_mpegts_drain_pes(
            pes,
            pes_length,
            elementary,
            elementary_capacity,
            elementary_length,
            audio_only,
            false
        );
        if (consumed <= 0) {
            break;
        }
    }
}

int32_t pm_mpegts_extract_audio(
    const uint8_t *data,
    int32_t length,
    uint8_t *out,
    int32_t out_capacity,
    uint8_t *scratch,
    int32_t scratch_capacity,
    int32_t *out_length
) {
    if (out_length != NULL) {
        *out_length = 0;
    }
    if (data == NULL || length <= 0 || out == NULL || scratch == NULL) {
        return PM_MPEGTS_KIND_NONE;
    }
    const int32_t packet_size = pm_mpegts_packet_size(data, length);
    if (packet_size <= 0) {
        return PM_MPEGTS_KIND_NONE;
    }

    int32_t pmt_pid = -1;
    int32_t offset = 0;
    while (offset + packet_size <= length) {
        int32_t pid = 0;
        bool unit_start = false;
        int32_t payload_offset = 0;
        int32_t payload_length = 0;
        if (pm_mpegts_parse_packet(
                data + offset,
                packet_size,
                &pid,
                &unit_start,
                &payload_offset,
                &payload_length
            )
            && pid == 0
            && pmt_pid < 0) {
            pmt_pid = pm_mpegts_parse_pat(
                data + offset + payload_offset,
                payload_length
            );
        }
        offset += packet_size;
    }

    int32_t audio_pid = -1;
    uint8_t stream_type = 0;
    if (pmt_pid >= 0) {
        offset = 0;
        while (offset + packet_size <= length) {
            int32_t pid = 0;
            bool unit_start = false;
            int32_t payload_offset = 0;
            int32_t payload_length = 0;
            if (pm_mpegts_parse_packet(
                    data + offset,
                    packet_size,
                    &pid,
                    &unit_start,
                    &payload_offset,
                    &payload_length
                )
                && pid == pmt_pid
                && pm_mpegts_parse_pmt(
                    data + offset + payload_offset,
                    payload_length,
                    &audio_pid,
                    &stream_type
                )) {
                break;
            }
            offset += packet_size;
        }
    }

    const bool audio_only = audio_pid < 0;
    int32_t pes_length = 0;
    int32_t elementary_length = 0;
    offset = 0;
    while (offset + packet_size <= length) {
        int32_t pid = 0;
        bool unit_start = false;
        int32_t payload_offset = 0;
        int32_t payload_length = 0;
        if (pm_mpegts_parse_packet(
                data + offset,
                packet_size,
                &pid,
                &unit_start,
                &payload_offset,
                &payload_length
            )
            && (audio_only || pid == audio_pid)) {
            pm_mpegts_append_and_drain(
                scratch,
                &pes_length,
                scratch_capacity,
                data + offset + payload_offset,
                payload_length,
                out,
                out_capacity,
                &elementary_length,
                audio_only
            );
        }
        offset += packet_size;
    }
    (void)pm_mpegts_drain_pes(
        scratch,
        &pes_length,
        out,
        out_capacity,
        &elementary_length,
        audio_only,
        true
    );

    if (elementary_length <= 32) {
        return PM_MPEGTS_KIND_NONE;
    }
    int32_t kind = pm_mpegts_kind_for_stream_type(stream_type);
    if (kind == PM_MPEGTS_KIND_NONE) {
        kind = pm_mpegts_infer_kind(out, elementary_length);
    }
    if (kind == PM_MPEGTS_KIND_NONE) {
        return PM_MPEGTS_KIND_NONE;
    }
    if (out_length != NULL) {
        *out_length = elementary_length;
    }
    return kind;
}

#pragma mark - ISO BMFF

uint32_t pm_iso_fourcc(const char *type) {
    if (type == NULL) {
        return 0;
    }
    uint32_t value = 0;
    for (int index = 0; index < 4; index++) {
        const unsigned char byte = (unsigned char)type[index];
        if (byte == 0) {
            break;
        }
        value = (value << 8) | byte;
    }
    return value;
}

static uint32_t pm_iso_load_u32(const uint8_t *data, int32_t offset) {
    return ((uint32_t)data[offset] << 24)
        | ((uint32_t)data[offset + 1] << 16)
        | ((uint32_t)data[offset + 2] << 8)
        | (uint32_t)data[offset + 3];
}

static uint64_t pm_iso_load_u64(const uint8_t *data, int32_t offset) {
    return ((uint64_t)pm_iso_load_u32(data, offset) << 32)
        | (uint64_t)pm_iso_load_u32(data, offset + 4);
}

static bool pm_iso_parse_box(
    const uint8_t *data,
    int32_t length,
    int32_t offset,
    int32_t limit,
    pm_iso_box *out,
    pm_iso_status *status
) {
    if (offset < 0 || offset + 8 > length || offset + 8 > limit) {
        if (status != NULL) {
            status->code = PM_ISO_TRUNCATED;
            status->expected = 8;
            status->available = length - (offset < 0 ? 0 : offset);
            if (status->available < 0) {
                status->available = 0;
            }
        }
        return false;
    }
    const uint32_t size32 = pm_iso_load_u32(data, offset);
    const uint32_t type = pm_iso_load_u32(data, offset + 4);
    int32_t header_size = 8;
    int64_t size = (int64_t)size32;
    if (size32 == 0) {
        if (offset + 8 > limit) {
            if (status != NULL) {
                status->code = PM_ISO_TRUNCATED;
                status->expected = 8;
                status->available = limit - offset;
                if (status->available < 0) {
                    status->available = 0;
                }
            }
            return false;
        }
        if (out != NULL) {
            out->type = type;
            out->start = offset;
            out->size = limit - offset;
            out->header_size = 8;
        }
        if (status != NULL) {
            status->code = PM_ISO_OK;
            status->expected = 0;
            status->available = 0;
        }
        return true;
    }
    if (size32 == 1) {
        if (offset + 16 > length) {
            if (status != NULL) {
                status->code = PM_ISO_TRUNCATED;
                status->expected = 16;
                status->available = length - offset;
                if (status->available < 0) {
                    status->available = 0;
                }
            }
            return false;
        }
        const uint64_t size64 = pm_iso_load_u64(data, offset + 8);
        if (size64 > (uint64_t)INT32_MAX || size64 < 16) {
            if (status != NULL) {
                status->code = PM_ISO_INVALID;
                status->expected = 0;
                status->available = 0;
            }
            return false;
        }
        header_size = 16;
        size = (int64_t)size64;
    } else if (size < 8) {
        if (status != NULL) {
            status->code = PM_ISO_INVALID;
            status->expected = 0;
            status->available = 0;
        }
        return false;
    }
    const int32_t remaining = limit - offset;
    if (remaining < 0 || size > remaining) {
        if (status != NULL) {
            status->code = PM_ISO_TRUNCATED;
            status->expected = (int32_t)size;
            status->available = remaining < 0 ? 0 : remaining;
        }
        return false;
    }
    if (out != NULL) {
        out->type = type;
        out->start = offset;
        out->size = (int32_t)size;
        out->header_size = header_size;
    }
    if (status != NULL) {
        status->code = PM_ISO_OK;
        status->expected = 0;
        status->available = 0;
    }
    return true;
}

int32_t pm_iso_walk(
    const uint8_t *data,
    int32_t length,
    int32_t start,
    int32_t end,
    pm_iso_box *out,
    int32_t out_capacity,
    pm_iso_status *status
) {
    pm_iso_status local = {PM_ISO_OK, 0, 0};
    pm_iso_status *st = status != NULL ? status : &local;
    st->code = PM_ISO_OK;
    st->expected = 0;
    st->available = 0;
    if (data == NULL || start < 0 || start > end || end > length) {
        st->code = PM_ISO_TRUNCATED;
        st->expected = end - start;
        if (st->expected < 0) {
            st->expected = 0;
        }
        st->available = length - start;
        if (st->available < 0) {
            st->available = 0;
        }
        return 0;
    }
    int32_t written = 0;
    int32_t offset = start;
    int32_t count = 0;
    while (offset + 8 <= end && count < PM_ISO_WALK_LIMIT) {
        count += 1;
        pm_iso_box box;
        if (!pm_iso_parse_box(data, length, offset, end, &box, st)) {
            return written;
        }
        if (out != NULL && written < out_capacity) {
            out[written] = box;
        }
        written += 1;
        if (box.size <= 0) {
            break;
        }
        if (box.size > end - offset) {
            break;
        }
        offset += box.size;
    }
    st->code = PM_ISO_OK;
    return written;
}

bool pm_iso_contains_types(
    const uint8_t *data,
    int32_t length,
    const uint32_t *types,
    int32_t type_count
) {
    if (type_count <= 0) {
        return true;
    }
    if (data == NULL || types == NULL || length < 8) {
        return false;
    }
    uint32_t remaining[16];
    int32_t remaining_count = type_count;
    if (remaining_count > 16) {
        remaining_count = 16;
    }
    memcpy(remaining, types, (size_t)remaining_count * sizeof(uint32_t));

    int32_t offset = 0;
    int32_t walked = 0;
    while (offset + 8 <= length
        && remaining_count > 0
        && walked < PM_ISO_WALK_LIMIT) {
        walked += 1;
        const uint32_t size32 = pm_iso_load_u32(data, offset);
        const uint32_t type = pm_iso_load_u32(data, offset + 4);
        for (int32_t type_index = 0; type_index < remaining_count; type_index++) {
            if (type != remaining[type_index]) {
                continue;
            }
            remaining[type_index] = remaining[remaining_count - 1];
            remaining_count -= 1;
            break;
        }
        if (remaining_count == 0) {
            return true;
        }

        int64_t box_size;
        if (size32 == 1) {
            if (offset + 16 > length) {
                break;
            }
            const uint64_t size64 = pm_iso_load_u64(data, offset + 8);
            box_size = size64 > (uint64_t)INT32_MAX
                ? (int64_t)(length - offset)
                : (int64_t)size64;
        } else if (size32 == 0) {
            box_size = (int64_t)(length - offset);
        } else {
            box_size = (int64_t)size32;
        }
        if (box_size < 8) {
            break;
        }
        if (box_size > (int64_t)(length - offset)) {
            break;
        }
        offset += (int32_t)box_size;
    }
    return remaining_count == 0;
}

#pragma mark - VK unmask

static const char pm_vk_alphabet[] =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN0PQRSTUVWXYZO123456789+/=";

static int pm_vk_alphabet_index(unsigned char character) {
    for (int index = 0; pm_vk_alphabet[index] != 0; index++) {
        if ((unsigned char)pm_vk_alphabet[index] == character) {
            return index;
        }
    }
    return -1;
}

static int32_t pm_vk_find(
    const uint8_t *data,
    int32_t length,
    const char *needle
) {
    if (data == NULL || needle == NULL) {
        return -1;
    }
    const int32_t needle_length = (int32_t)strlen(needle);
    if (needle_length <= 0 || needle_length > length) {
        return -1;
    }
    for (int32_t index = 0; index + needle_length <= length; index++) {
        if (memcmp(data + index, needle, (size_t)needle_length) == 0) {
            return index;
        }
    }
    return -1;
}

static int32_t pm_vk_decode(
    const uint8_t *value,
    int32_t length,
    uint8_t *out,
    int32_t out_capacity
) {
    int32_t written = 0;
    int accumulator = 0;
    int position = 0;
    for (int32_t index = 0; index < length; index++) {
        const int raw = pm_vk_alphabet_index(value[index]);
        if (raw < 0) {
            continue;
        }
        accumulator = position % 4 == 0 ? raw : 64 * accumulator + raw;
        const int previous = position;
        position += 1;
        if (previous % 4 == 0) {
            continue;
        }
        if (written >= out_capacity) {
            return PM_VK_UNMASK_OVERFLOW;
        }
        const int shift = (-2 * position) & 6;
        out[written] = (uint8_t)((accumulator >> shift) & 255);
        written += 1;
    }
    return written == 0 ? PM_VK_UNMASK_FAILED : written;
}

int32_t pm_vk_unmask(
    const uint8_t *raw,
    int32_t raw_length,
    int32_t user_id,
    uint8_t *out,
    int32_t out_capacity
) {
    if (raw == NULL || raw_length <= 0) {
        return PM_VK_UNMASK_FAILED;
    }
    if (pm_vk_find(raw, raw_length, "audio_api_unavailable") < 0) {
        return PM_VK_UNMASK_NOT_MASKED;
    }
    const int32_t extra = pm_vk_find(raw, raw_length, "?extra=");
    if (extra < 0) {
        return PM_VK_UNMASK_FAILED;
    }
    const int32_t encoded_start = extra + 7;
    if (encoded_start >= raw_length) {
        return PM_VK_UNMASK_FAILED;
    }
    int32_t hash = -1;
    for (int32_t index = encoded_start; index < raw_length; index++) {
        if (raw[index] == '#') {
            hash = index;
            break;
        }
    }
    if (hash < 0 || hash + 1 >= raw_length) {
        return PM_VK_UNMASK_FAILED;
    }

    uint8_t url_bytes[4096];
    uint8_t key_bytes[256];
    const int32_t url_decoded = pm_vk_decode(
        raw + encoded_start,
        hash - encoded_start,
        url_bytes,
        4096
    );
    if (url_decoded <= 0) {
        return PM_VK_UNMASK_FAILED;
    }
    const int32_t key_decoded = pm_vk_decode(
        raw + hash + 1,
        raw_length - (hash + 1),
        key_bytes,
        256
    );
    if (key_decoded <= 0) {
        return PM_VK_UNMASK_FAILED;
    }

    int32_t tab = -1;
    for (int32_t index = 0; index < key_decoded; index++) {
        if (key_bytes[index] == 0x0B) {
            tab = index;
            break;
        }
    }
    if (tab < 0 || tab + 1 >= key_decoded) {
        return PM_VK_UNMASK_FAILED;
    }
    int64_t parsed_key = 0;
    bool have_digit = false;
    for (int32_t index = tab + 1; index < key_decoded; index++) {
        const uint8_t byte = key_bytes[index];
        if (byte == 0x0B) {
            break;
        }
        if (byte < '0' || byte > '9') {
            if (!have_digit) {
                return PM_VK_UNMASK_FAILED;
            }
            break;
        }
        have_digit = true;
        parsed_key = parsed_key * 10 + (byte - '0');
        if (parsed_key > INT32_MAX) {
            return PM_VK_UNMASK_FAILED;
        }
    }
    if (!have_digit) {
        return PM_VK_UNMASK_FAILED;
    }

    if (url_decoded > out_capacity) {
        return PM_VK_UNMASK_OVERFLOW;
    }
    memcpy(out, url_bytes, (size_t)url_decoded);
    const int32_t character_length = url_decoded;
    int32_t state = (int32_t)parsed_key ^ user_id;
    int32_t indexes[4096];
    if (character_length > 4096) {
        return PM_VK_UNMASK_OVERFLOW;
    }
    for (int32_t position = character_length - 1; position >= 0; position--) {
        state = ((character_length * (position + 1)) ^ (state + position))
            % character_length;
        if (state < 0) {
            state += character_length;
        }
        indexes[position] = state;
    }
    if (character_length > 1) {
        for (int32_t position = 1; position < character_length; position++) {
            const int32_t target = indexes[character_length - 1 - position];
            const uint8_t swap = out[position];
            out[position] = out[target];
            out[target] = swap;
        }
    }
    return character_length;
}

#pragma mark - Loaded-ahead fold

double pm_buffer_max_loaded_ahead(
    double position_seconds,
    const double *end_seconds,
    int32_t count
) {
    if (end_seconds == NULL || count <= 0 || !isfinite(position_seconds)) {
        return 0.0;
    }
    double loaded_ahead = 0.0;
    for (int32_t index = 0; index < count; index++) {
        const double end = end_seconds[index];
        if (!isfinite(end)) {
            continue;
        }
        const double ahead = end - position_seconds;
        if (isfinite(ahead) && ahead > loaded_ahead) {
            loaded_ahead = ahead;
        }
    }
    if (loaded_ahead < 0.0) {
        return 0.0;
    }
    return loaded_ahead;
}
