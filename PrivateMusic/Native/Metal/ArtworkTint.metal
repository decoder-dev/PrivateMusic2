#include <metal_stdlib>
using namespace metal;

/// Saturation-weighted RGBA average for Bubble artwork tints. Each thread
/// handles one pixel and atomically accumulates weighted colour channels.
kernel void pm_artwork_tint_reduce(
    constant uint &pixel_count [[buffer(0)]],
    device const uchar4 *pixels [[buffer(1)]],
    device atomic_float *weighted_rgbw [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= pixel_count) {
        return;
    }

    const uchar4 pixel = pixels[id];
    const float alpha = float(pixel.w) / 255.0f;
    if (alpha <= 0.4f) {
        return;
    }

    const float red = float(pixel.x) / 255.0f;
    const float green = float(pixel.y) / 255.0f;
    const float blue = float(pixel.z) / 255.0f;
    const float high = max(red, max(green, blue));
    const float low = min(red, min(green, blue));
    const float saturation = high > 0.0f ? (high - low) / high : 0.0f;
    const float weight = alpha * (0.08f + saturation);

    atomic_fetch_add_explicit(
        &weighted_rgbw[0],
        red * weight,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &weighted_rgbw[1],
        green * weight,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &weighted_rgbw[2],
        blue * weight,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &weighted_rgbw[3],
        weight,
        memory_order_relaxed
    );
}
