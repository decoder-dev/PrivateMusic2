import Accelerate
import AudioToolbox
import AVFoundation
import MediaToolbox

final class EqualizerDSP: @unchecked Sendable {
    static let frequencies: [Double] = [
        31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    private struct Coefficients {
        let b0: Float
        let b1: Float
        let b2: Float
        let a1: Float
        let a2: Float
    }

    private let lock = NSLock()
    private var enabled = false
    private var gains = [Double](repeating: 0, count: 10)
    private var preampDB = 0.0
    private var coefficients = [Coefficients]()
    private var preamp: Float = 1
    private var states = [Float]()
    private var sampleRate = 44_100.0
    private var channelCount = 2
    private var supportsProcessing = false
    private var loudnessNormEnabled = false
    private var drcEnabled = false
    private var loudnessGain: Float = 1.0
    private var compressorThreshold: Float = 0.5
    private var compressorRatio: Float = 4.0
    private var compressorMakeupGain: Float = 1.0
    private var envelope: Float = 0

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func update(
        enabled: Bool,
        gains: [Double],
        preamp: Double,
        loudnessNorm: Bool = false,
        dynamicRangeCompression: Bool = false
    ) {
        lock.lock()
        self.enabled = enabled
        if gains.count == Self.frequencies.count {
            self.gains = gains
        }
        preampDB = min(max(preamp, -12), 6)
        loudnessNormEnabled = loudnessNorm
        drcEnabled = dynamicRangeCompression
        rebuildCoefficients()
        lock.unlock()
    }

    func makeTap() -> MTAudioProcessingTap? {
        guard isEnabled else { return nil }
        let retained = Unmanaged.passRetained(self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: equalizerTapInit,
            finalize: equalizerTapFinalize,
            prepare: equalizerTapPrepare,
            unprepare: equalizerTapUnprepare,
            process: equalizerTapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let tap else {
            retained.release()
            return nil
        }
        return tap
    }

    fileprivate func prepare(
        processingFormat: UnsafePointer<AudioStreamBasicDescription>
    ) {
        let format = processingFormat.pointee
        lock.lock()
        sampleRate = format.mSampleRate
        channelCount = max(Int(format.mChannelsPerFrame), 1)
        supportsProcessing =
            format.mFormatID == kAudioFormatLinearPCM
            && format.mBitsPerChannel == 32
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        states = [Float](
            repeating: 0,
            count: channelCount * Self.frequencies.count * 4
        )
        rebuildCoefficients()
        lock.unlock()
    }

    fileprivate func unprepare() {
        lock.lock()
        states.removeAll(keepingCapacity: false)
        supportsProcessing = false
        lock.unlock()
    }

    fileprivate func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard enabled,
              supportsProcessing,
              !coefficients.isEmpty else {
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let nonInterleaved = buffers.count > 1

        for bufferIndex in buffers.indices {
            guard let rawData = buffers[bufferIndex].mData else { continue }
            let samples = rawData.assumingMemoryBound(to: Float.self)
            let channelsInBuffer = max(
                Int(buffers[bufferIndex].mNumberChannels),
                1
            )
            let stride = nonInterleaved ? 1 : channelsInBuffer

            for localChannel in 0..<channelsInBuffer {
                let channel = nonInterleaved
                    ? min(bufferIndex, channelCount - 1)
                    : min(localChannel, channelCount - 1)
                var sampleIndex = localChannel

                for _ in 0..<frameCount {
                    var value = samples[sampleIndex] * preamp

                    for band in coefficients.indices {
                        let stateIndex = (channel * coefficients.count + band)
                            * 4
                        let coefficient = coefficients[band]
                        let x1 = states[stateIndex]
                        let x2 = states[stateIndex + 1]
                        let y1 = states[stateIndex + 2]
                        let y2 = states[stateIndex + 3]
                        let output = coefficient.b0 * value
                            + coefficient.b1 * x1
                            + coefficient.b2 * x2
                            - coefficient.a1 * y1
                            - coefficient.a2 * y2
                        states[stateIndex] = value
                        states[stateIndex + 1] = x1
                        states[stateIndex + 2] = output
                        states[stateIndex + 3] = y1
                        value = output
                    }

                    if drcEnabled {
                        let absVal = abs(value)
                        let target = absVal > compressorThreshold
                            ? compressorThreshold
                                + (absVal - compressorThreshold)
                                / compressorRatio
                            : absVal
                        let peakGain = absVal > 0.001
                            ? target / absVal
                            : 1
                        envelope += (peakGain - envelope) * 0.01
                        value *= envelope * compressorMakeupGain
                    }

                    if loudnessNormEnabled {
                        value *= loudnessGain
                    }

                    samples[sampleIndex] = min(max(value, -1), 1)
                    sampleIndex += stride
                }
            }
        }
    }

    private func rebuildCoefficients() {
        let headroom = max(gains.max() ?? 0, 0)
        preamp = Float(pow(10, (preampDB - headroom) / 20))
        coefficients = zip(Self.frequencies, gains).map {
            peakingCoefficients(
                frequency: $0.0,
                gain: $0.1,
                sampleRate: sampleRate
            )
        }
        // Target: -14 LUFS (Spotify/streaming standard)
        // Simple gain offset assuming typical VK stream at ~-10 LUFS
        loudnessNormEnabled
            ? { loudnessGain = Float(pow(10, -4.0 / 20)) }()
            : { loudnessGain = 1.0 }()
        compressorThreshold = 0.6
        compressorRatio = 3.0
        compressorMakeupGain = loudnessNormEnabled ? 1.5 : 1.2
        envelope = 0
    }

    private func peakingCoefficients(
        frequency: Double,
        gain: Double,
        sampleRate: Double
    ) -> Coefficients {
        let safeFrequency = min(frequency, sampleRate * 0.45)
        let amplitude = pow(10, gain / 40)
        let omega = 2 * Double.pi * safeFrequency / sampleRate
        let alpha = sin(omega) / (2 * 1.15)
        let cosine = cos(omega)
        let a0 = 1 + alpha / amplitude

        return Coefficients(
            b0: Float((1 + alpha * amplitude) / a0),
            b1: Float((-2 * cosine) / a0),
            b2: Float((1 - alpha * amplitude) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha / amplitude) / a0)
        )
    }
}

private let equalizerTapInit: MTAudioProcessingTapInitCallback = {
    _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let equalizerTapFinalize: MTAudioProcessingTapFinalizeCallback = {
    tap in
    Unmanaged<EqualizerDSP>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .release()
}

private let equalizerTapPrepare: MTAudioProcessingTapPrepareCallback = {
    tap, _, processingFormat in
    let processor = Unmanaged<EqualizerDSP>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    processor.prepare(processingFormat: processingFormat)
}

private let equalizerTapUnprepare: MTAudioProcessingTapUnprepareCallback = {
    tap in
    let processor = Unmanaged<EqualizerDSP>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    processor.unprepare()
}

private let equalizerTapProcess: MTAudioProcessingTapProcessCallback = {
    tap,
    numberFrames,
    flags,
    bufferList,
    numberFramesOut,
    flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferList,
        flagsOut,
        nil,
        numberFramesOut
    )
    guard status == noErr else {
        numberFramesOut.pointee = 0
        return
    }
    flagsOut.pointee = flagsOut.pointee | flags
    let processor = Unmanaged<EqualizerDSP>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
        .takeUnretainedValue()
    processor.process(
        bufferList: bufferList,
        frameCount: numberFramesOut.pointee
    )
}
