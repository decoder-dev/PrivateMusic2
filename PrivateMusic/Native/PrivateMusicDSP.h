#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Direct-form IIR peaking / shelf / high-pass coefficients.
typedef struct PMBiquadCoeffs {
    float b0;
    float b1;
    float b2;
    float a1;
    float a2;
} PMBiquadCoeffs;

/// Process one biquad sample. `state` is exactly 4 floats: x1,x2,y1,y2.
float pm_biquad_process(
    float input,
    const PMBiquadCoeffs *coeffs,
    float *state
);

/// Apply a cascade of peaking EQ bands (+ optional DRC / loudness) to one
/// channel of interleaved or planar float PCM. Hot path for MTAudioProcessingTap.
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
);

/// Mid/side stereo widen used by SpatialAudioDSP.
/// Intensity is clamped to [0, 1]. Returns widened L/R without hard clipping
/// beyond the fixed headroom scale (caller may still clamp to [-1, 1]).
void pm_spatial_widen(
    float left,
    float right,
    float intensity,
    float processed_side,
    bool has_processed_side,
    float *out_left,
    float *out_right
);

#ifdef __cplusplus
}
#endif
