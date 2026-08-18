import Foundation
import Metal

/// GPU reduction for Bubble artwork tint extraction. Falls back to the C path
/// in `BubbleArtworkTint` when Metal is unavailable (previews, sim edge cases).
enum ArtworkTintGPU {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let pipeline: MTLComputePipelineState? = {
        guard let device,
              let library = device.makeDefaultLibrary(),
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
