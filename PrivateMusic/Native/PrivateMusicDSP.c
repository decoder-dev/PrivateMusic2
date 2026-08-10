#include "PrivateMusicDSP.h"

#include <math.h>

float pm_biquad_process(
    float input,
    const PMBiquadCoeffs *coeffs,
    float *state
) {
    const float x1 = state[0];
    const float x2 = state[1];
    const float y1 = state[2];
    const float y2 = state[3];
    const float output = coeffs->b0 * input
        + coeffs->b1 * x1
        + coeffs->b2 * x2
        - coeffs->a1 * y1
        - coeffs->a2 * y2;
    state[0] = input;
    state[1] = x1;
    state[2] = output;
    state[3] = y1;
    return output;
}

void pm_eq_process_channel(
    float *samples,
    int frame_count,
    int stride,
    const PMBiquadCoeffs *bands,
    int band_count,
    float *band_states,
    float preamp,
    bool drc_enabled,
    float compressor_threshold,
    float compressor_ratio,
    float compressor_makeup,
    float *envelope_inout,
    bool loudness_enabled,
    float loudness_gain
) {
    if (samples == NULL || frame_count <= 0 || stride <= 0) {
        return;
    }
    if (band_count > 0 && (bands == NULL || band_states == NULL)) {
        return;
    }

    float envelope = envelope_inout != NULL ? *envelope_inout : 0.0f;
    int sample_index = 0;

    for (int frame = 0; frame < frame_count; ++frame) {
        float value = samples[sample_index] * preamp;

        for (int band = 0; band < band_count; ++band) {
            float *state = band_states + (band * 4);
            value = pm_biquad_process(value, &bands[band], state);
        }

        if (drc_enabled) {
            const float abs_val = fabsf(value);
            const float target = abs_val > compressor_threshold
                ? compressor_threshold
                    + (abs_val - compressor_threshold) / compressor_ratio
                : abs_val;
            const float peak_gain = abs_val > 0.001f
                ? target / abs_val
                : 1.0f;
            envelope += (peak_gain - envelope) * 0.01f;
            value *= envelope * compressor_makeup;
        }

        if (loudness_enabled) {
            value *= loudness_gain;
        }

        if (value > 1.0f) {
            value = 1.0f;
        } else if (value < -1.0f) {
            value = -1.0f;
        }

        samples[sample_index] = value;
        sample_index += stride;
    }

    if (envelope_inout != NULL) {
        *envelope_inout = envelope;
    }
}

void pm_spatial_widen(
    float left,
    float right,
    float intensity,
    float processed_side,
    bool has_processed_side,
    float *out_left,
    float *out_right
) {
    if (out_left == NULL || out_right == NULL) {
        return;
    }

    float amount = intensity;
    if (amount < 0.0f) {
        amount = 0.0f;
    } else if (amount > 1.0f) {
        amount = 1.0f;
    }

    if (amount <= 0.0f) {
        *out_left = left;
        *out_right = right;
        return;
    }

    const float mid = (left + right) * 0.5f;
    const float side = has_processed_side
        ? processed_side
        : (left - right) * 0.5f;
    const float maximum_side_gain = 1.22f;
    const float side_gain = 1.0f + (maximum_side_gain - 1.0f) * amount;
    const float headroom = 1.0f / side_gain;
    *out_left = (mid + side * side_gain) * headroom;
    *out_right = (mid - side * side_gain) * headroom;
}
