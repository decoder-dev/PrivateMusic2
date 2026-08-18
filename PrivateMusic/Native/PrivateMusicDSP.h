#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

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

/// Run one biquad across a whole channel of interleaved or planar float PCM.
/// Hot path for the route-tone boom cut: keeps the per-sample filter, the
/// clamp and the stride walk inside C instead of paying a Swift call plus a
/// coefficient copy for every frame.
/// `state` is exactly 4 floats: x1,x2,y1,y2.
void pm_biquad_process_channel(
    float *samples,
    int frame_count,
    int stride,
    const PMBiquadCoeffs *coeffs,
    float *state,
    bool clamp_output
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

/// Widen a planar stereo pair in place, high-passing the side channel first so
/// bass stays centred. Pass `has_side_high_pass` false to widen without
/// filtering, which also leaves `side_state` untouched. `side_state` is
/// exactly 4 floats and carries over between callbacks. Intensity is clamped
/// to [0, 1]; values at or below zero leave the buffers untouched.
void pm_spatial_process_planar(
    float *left,
    float *right,
    int frame_count,
    float intensity,
    const PMBiquadCoeffs *side_high_pass,
    bool has_side_high_pass,
    float *side_state
);

/// Interleaved counterpart of `pm_spatial_process_planar`. `stride` is the
/// frame stride in floats; left/right are the first two channels of a frame.
void pm_spatial_process_interleaved(
    float *samples,
    int frame_count,
    int stride,
    float intensity,
    const PMBiquadCoeffs *side_high_pass,
    bool has_side_high_pass,
    float *side_state
);

/// Peak magnitude of a float PCM buffer. Uses Accelerate/vDSP from C so the
/// MTAudioProcessingTap silence gate never crosses into Swift.
float pm_buffer_peak_magnitude(const float *samples, int32_t count);

#ifdef __cplusplus
}
#endif
