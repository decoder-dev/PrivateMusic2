import Foundation
import Metal

/// GPU reduction for Bubble artwork tint extraction. The kernel is compiled at
/// runtime so CI archives do not require the standalone Metal Toolchain for a
/// `.metal` build phase. Falls back to the C path in `BubbleArtworkTint` when
/// Metal is unavailable.
enum ArtworkTintGPU {
    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

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
    """

    private static let device = MTLCreateSystemDefaultDevice()
    private static let pipeline: MTLComputePipelineState? = {
        guard let device else { return nil }
        let source = kernelSource
        guard let library = try? device.makeLibrary(
            source: source,
            options: nil
        ),
            let function = library.makeFunction(
                name: "pm_artwork_tint_reduce"
            ) else {
            return nil
        }
        return try? device.makeComputePipelineState(function: function)
    }()

    static func extract(rgba: [UInt8]) -> BubbleColorComponents? {
        guard rgba.count >= 4, rgba.count % 4 == 0,
              let device,
              let pipeline,
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        let pixelCount = rgba.count / 4
        guard let pixelBuffer = device.makeBuffer(
            bytes: rgba,
            length: rgba.count,
            options: .storageModeShared
        ),
            let countBuffer = device.makeBuffer(
                length: MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            ),
            let sumBuffer = device.makeBuffer(
                length: MemoryLayout<Float>.stride * 4,
                options: .storageModeShared
            ),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        countBuffer.contents()
            .assumingMemoryBound(to: UInt32.self)
            .pointee = UInt32(pixelCount)
        memset(sumBuffer.contents(), 0, MemoryLayout<Float>.stride * 4)

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(countBuffer, offset: 0, index: 0)
        encoder.setBuffer(pixelBuffer, offset: 0, index: 1)
        encoder.setBuffer(sumBuffer, offset: 0, index: 2)

        let width = pipeline.threadExecutionWidth
        let groups = (pixelCount + width - 1) / width
        encoder.dispatchThreadgroups(
            MTLSize(width: groups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let sums = sumBuffer.contents().assumingMemoryBound(to: Float.self)
        let totalWeight = Double(sums[3])
        guard totalWeight > 0 else { return nil }

        return BubbleColorComponents(
            red: Double(sums[0]) / totalWeight,
            green: Double(sums[1]) / totalWeight,
            blue: Double(sums[2]) / totalWeight
        )
    }
}
