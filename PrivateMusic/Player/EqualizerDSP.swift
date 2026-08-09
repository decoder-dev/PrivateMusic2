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

    private struct BuiltCoefficients {
        let equalizer: [Coefficients]
        let preamp: Float
        let loudnessGain: Float
        let compressorThreshold: Float
        let compressorRatio: Float
        let compressorMakeupGain: Float
        let boomCut: Coefficients?
        let sideHighPass: Coefficients
    }

    private struct CoefficientConfiguration {
        let gains: [Double]
        let preampDB: Double
        let loudnessNormEnabled: Bool
        let outputProfile: PlaybackOutputToneProfile
        let sampleRate: Double
    }

    private let lock = NSLock()
    private var coefficientRevision = 0
    private var enabled = false
    private var gains = [Double](repeating: 0, count: 10)
    private var preampDB = 0.0
    private var coefficients = [Coefficients]()
    private var preamp: Float = 1
    private var states = [Float]()
    private var sampleRate = 44_100.0
    private var channelCount = 2
    private var isNonInterleaved = false
    private var frameStride = 2
    private var supportsProcessing = false
    private var loudnessNormEnabled = false
    private var drcEnabled = false
    private var spatialAudioEnabled = false
    private var spatialAudioIntensity = SpatialAudioDSP.defaultIntensity
    private var loudnessGain: Float = 1.0
    private var compressorThreshold: Float = 0.5
    private var compressorRatio: Float = 4.0
    private var compressorMakeupGain: Float = 1.0
    private var envelope: Float = 0
    private var outputProfile: PlaybackOutputToneProfile = .intimate
    private var boomCutCoefficients: Coefficients?
    private var boomCutStates = [Float](repeating: 0, count: 8)
    private var sideHighPassCoefficients: Coefficients?
    private var sideHighPassState = [Float](repeating: 0, count: 4)

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    var requiresAudioTap: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasActiveEqualizerProcessing
            || isSpatialAudioActive
            || outputProfile.needsClarityProcessing
    }

    /// Flat EQ with zero preamp and no loudness/DRC is a no-op — skip the
    /// realtime tap so CarKit / AirPlay external handoff stays available and
    /// the device does not burn CPU on identity biquads.
    private var hasActiveEqualizerProcessing: Bool {
        guard enabled else { return false }
        if loudnessNormEnabled || drcEnabled { return true }
        if abs(preampDB) > 0.000_1 { return true }
        return gains.contains { abs($0) > 0.000_1 }
    }

    func setOutputProfile(_ profile: PlaybackOutputToneProfile) {
        lock.lock()
        let changed = outputProfile != profile
        outputProfile = profile
        guard changed else {
            lock.unlock()
            return
        }
        coefficientRevision &+= 1
        let revision = coefficientRevision
        let configuration = coefficientConfiguration
        lock.unlock()

        let built = Self.buildCoefficients(configuration)
        lock.lock()
        if coefficientRevision == revision {
            apply(built)
            boomCutStates = [Float](repeating: 0, count: 8)
            sideHighPassState = [Float](repeating: 0, count: 4)
        }
        lock.unlock()
    }

    func update(
        enabled: Bool,
        gains: [Double],
        preamp: Double,
        loudnessNorm: Bool = false,
        dynamicRangeCompression: Bool = false,
        spatialAudio: Bool = false,
        spatialIntensity: Double = SpatialAudioDSP.defaultIntensity
    ) {
        lock.lock()
        let normalizedGains = gains.count == Self.frequencies.count
            ? gains
            : self.gains
        let normalizedPreamp = min(max(preamp, -12), 6)
        let rebuildRequired =
            self.gains != normalizedGains
            || preampDB != normalizedPreamp
            || loudnessNormEnabled != loudnessNorm
            || drcEnabled != dynamicRangeCompression
        self.enabled = enabled
        self.gains = normalizedGains
        preampDB = normalizedPreamp
        loudnessNormEnabled = loudnessNorm
        drcEnabled = dynamicRangeCompression
        spatialAudioEnabled = spatialAudio
        spatialAudioIntensity = min(max(spatialIntensity, 0), 1)
        guard rebuildRequired else {
            lock.unlock()
            return
        }
        coefficientRevision &+= 1
        let revision = coefficientRevision
        let configuration = coefficientConfiguration
        lock.unlock()

        let built = Self.buildCoefficients(configuration)
        lock.lock()
        if coefficientRevision == revision {
            apply(built)
        }
        lock.unlock()
    }

    func makeTap() -> MTAudioProcessingTap? {
        guard requiresAudioTap else { return nil }
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
        isNonInterleaved =
            (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        frameStride = max(
            Int(format.mBytesPerFrame) / MemoryLayout<Float>.size,
            1
        )
        supportsProcessing =
            format.mFormatID == kAudioFormatLinearPCM
            && format.mBitsPerChannel == 32
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && (isNonInterleaved || frameStride >= channelCount)
        states = [Float](
            repeating: 0,
            count: channelCount * Self.frequencies.count * 4
        )
        boomCutStates = [Float](repeating: 0, count: max(channelCount, 2) * 4)
        sideHighPassState = [Float](repeating: 0, count: 4)
        coefficientRevision &+= 1
        rebuildCoefficients()
        lock.unlock()
    }

    fileprivate func unprepare() {
        lock.lock()
        states.removeAll(keepingCapacity: false)
        boomCutStates = [Float](repeating: 0, count: 8)
        sideHighPassState = [Float](repeating: 0, count: 4)
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
        let equalizerActive = hasActiveEqualizerProcessing
        let spatialAudioActive = isSpatialAudioActive
        let clarityActive = outputProfile.needsClarityProcessing
        guard supportsProcessing,
              equalizerActive || spatialAudioActive || clarityActive else {
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        if isNearlySilent(buffers: buffers, frameCount: frameCount),
           !hasSignificantFilterState {
            return
        }
        if equalizerActive, !coefficients.isEmpty {
            processEqualizer(
                buffers: buffers,
                frameCount: frameCount
            )
        }
        if clarityActive {
            processBoomCut(
                buffers: buffers,
                frameCount: frameCount
            )
        }
        if spatialAudioActive {
            processSpatialAudio(
                buffers: buffers,
                frameCount: frameCount
            )
        }
    }

    private var hasSignificantFilterState: Bool {
        for value in states where abs(value) > 0.000_5 {
            return true
        }
        for value in boomCutStates where abs(value) > 0.000_5 {
            return true
        }
        for value in sideHighPassState where abs(value) > 0.000_5 {
            return true
        }
        return abs(envelope) > 0.000_5
    }

    private func isNearlySilent(
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) -> Bool {
        var peak: Float = 0
        for buffer in buffers {
            guard let rawData = buffer.mData else { continue }
            let samples = rawData.assumingMemoryBound(to: Float.self)
            let count = frameCount * max(Int(buffer.mNumberChannels), 1)
            var localPeak: Float = 0
            vDSP_maxmgv(samples, 1, &localPeak, vDSP_Length(count))
            peak = max(peak, localPeak)
            if peak > 0.000_5 {
                return false
            }
        }
        return true
    }

    private func processEqualizer(
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        // The inner loops below run once per sample per band (10 bands x
        // every channel x every frame, continuously during playback).
        // Bouncing through Swift's Array subscript there pays for a bounds
        // check and a copy-on-write uniqueness check on every access; both
        // are provably unnecessary here since neither array is resized or
        // shared while the tap is running. Hoisting raw pointers once per
        // buffer callback removes that overhead from the hot path.
        coefficients.withUnsafeBufferPointer { coefficientsBuffer in
            states.withUnsafeMutableBufferPointer { statesBuffer in
                guard let coefficientsBase = coefficientsBuffer.baseAddress,
                      let statesBase = statesBuffer.baseAddress else {
                    return
                }
                let bandCount = coefficientsBuffer.count

                for bufferIndex in buffers.indices {
                    guard let rawData = buffers[bufferIndex].mData else {
                        continue
                    }
                    let samples = rawData.assumingMemoryBound(to: Float.self)
                    let channelsInBuffer = max(
                        Int(buffers[bufferIndex].mNumberChannels),
                        1
                    )
                    if isNonInterleaved, channelsInBuffer != 1 {
                        continue
                    }
                    let stride = isNonInterleaved ? 1 : frameStride

                    for localChannel in 0..<channelsInBuffer {
                        let channel = isNonInterleaved
                            ? min(bufferIndex, channelCount - 1)
                            : min(localChannel, channelCount - 1)
                        var sampleIndex = localChannel
                        let channelState = statesBase
                            + channel * bandCount * 4

                        for _ in 0..<frameCount {
                            var value = samples[sampleIndex] * preamp

                            var stateOffset = 0
                            for band in 0..<bandCount {
                                let coefficient = coefficientsBase[band]
                                let state = channelState + stateOffset
                                let x1 = state[0]
                                let x2 = state[1]
                                let y1 = state[2]
                                let y2 = state[3]
                                let output = coefficient.b0 * value
                                    + coefficient.b1 * x1
                                    + coefficient.b2 * x2
                                    - coefficient.a1 * y1
                                    - coefficient.a2 * y2
                                state[0] = value
                                state[1] = x1
                                state[2] = output
                                state[3] = y1
                                value = output
                                stateOffset += 4
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
        }
    }

    private func processBoomCut(
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        guard let coefficient = boomCutCoefficients else { return }
        boomCutStates.withUnsafeMutableBufferPointer { statesBuffer in
            guard let statesBase = statesBuffer.baseAddress else { return }
            for bufferIndex in buffers.indices {
                guard let rawData = buffers[bufferIndex].mData else {
                    continue
                }
                let samples = rawData.assumingMemoryBound(to: Float.self)
                let channelsInBuffer = max(
                    Int(buffers[bufferIndex].mNumberChannels),
                    1
                )
                if isNonInterleaved, channelsInBuffer != 1 {
                    continue
                }
                let stride = isNonInterleaved ? 1 : frameStride

                for localChannel in 0..<channelsInBuffer {
                    let channel = isNonInterleaved
                        ? min(bufferIndex, channelCount - 1)
                        : min(localChannel, channelCount - 1)
                    let stateIndex =
                        min(channel, statesBuffer.count / 4 - 1) * 4
                    let state = statesBase + stateIndex
                    var sampleIndex = localChannel
                    for _ in 0..<frameCount {
                        let input = samples[sampleIndex]
                        let output = applyBiquad(
                            input: input,
                            coefficient: coefficient,
                            state: state
                        )
                        samples[sampleIndex] = min(max(output, -1), 1)
                        sampleIndex += stride
                    }
                }
            }
        }
    }

    private func processSpatialAudio(
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        guard channelCount >= 2 else { return }
        let intensity = SpatialAudioDSP.effectiveIntensity(
            userIntensity: spatialAudioIntensity,
            profile: outputProfile
        )
        guard intensity > 0.000_1 else { return }

        sideHighPassState.withUnsafeMutableBufferPointer { stateBuffer in
            guard let sideState = stateBuffer.baseAddress else { return }

            if isNonInterleaved {
                guard buffers.count >= 2,
                      buffers[0].mNumberChannels == 1,
                      buffers[1].mNumberChannels == 1,
                      let leftData = buffers[0].mData,
                      let rightData = buffers[1].mData else {
                    return
                }
                let left = leftData.assumingMemoryBound(to: Float.self)
                let right = rightData.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    let side = (left[frame] - right[frame]) * 0.5
                    let filteredSide = highPassSide(side, state: sideState)
                    let widened = SpatialAudioDSP.process(
                        left: left[frame],
                        right: right[frame],
                        intensity: intensity,
                        processedSide: filteredSide
                    )
                    left[frame] = widened.left
                    right[frame] = widened.right
                }
                return
            }

            guard let buffer = buffers.first,
                  buffer.mNumberChannels >= 2,
                  let rawData = buffer.mData else {
                return
            }
            let samples = rawData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                let index = frame * frameStride
                let side = (samples[index] - samples[index + 1]) * 0.5
                let filteredSide = highPassSide(side, state: sideState)
                let widened = SpatialAudioDSP.process(
                    left: samples[index],
                    right: samples[index + 1],
                    intensity: intensity,
                    processedSide: filteredSide
                )
                samples[index] = widened.left
                samples[index + 1] = widened.right
            }
        }
    }

    private func highPassSide(
        _ side: Float,
        state: UnsafeMutablePointer<Float>
    ) -> Float {
        guard let coefficient = sideHighPassCoefficients else {
            return side
        }
        return applyBiquad(input: side, coefficient: coefficient, state: state)
    }

    private func applyBiquad(
        input: Float,
        coefficient: Coefficients,
        state: UnsafeMutablePointer<Float>
    ) -> Float {
        let x1 = state[0]
        let x2 = state[1]
        let y1 = state[2]
        let y2 = state[3]
        let output = coefficient.b0 * input
            + coefficient.b1 * x1
            + coefficient.b2 * x2
            - coefficient.a1 * y1
            - coefficient.a2 * y2
        state[0] = input
        state[1] = x1
        state[2] = output
        state[3] = y1
        return output
    }

    private var isSpatialAudioActive: Bool {
        spatialAudioEnabled && spatialAudioIntensity > 0.000_1
    }

    /// Access only while holding `lock`.
    private var coefficientConfiguration: CoefficientConfiguration {
        CoefficientConfiguration(
            gains: gains,
            preampDB: preampDB,
            loudnessNormEnabled: loudnessNormEnabled,
            outputProfile: outputProfile,
            sampleRate: sampleRate
        )
    }

    private func rebuildCoefficients() {
        apply(Self.buildCoefficients(coefficientConfiguration))
    }

    private static func buildCoefficients(
        _ configuration: CoefficientConfiguration
    ) -> BuiltCoefficients {
        let headroom = max(configuration.gains.max() ?? 0, 0)
        let preamp = Float(
            pow(10, (configuration.preampDB - headroom) / 20)
        )
        let equalizer = zip(Self.frequencies, configuration.gains).map {
            Self.peakingCoefficients(
                frequency: $0.0,
                gain: $0.1,
                sampleRate: configuration.sampleRate
            )
        }
        // Target: -14 LUFS (Spotify/streaming standard)
        // Simple gain offset assuming typical VK stream at ~-10 LUFS
        let loudnessGain = configuration.loudnessNormEnabled
            ? Float(pow(10, -4.0 / 20))
            : 1.0
        let boomCut: Coefficients?
        if configuration.outputProfile.needsClarityProcessing {
            boomCut = Self.lowShelfCoefficients(
                frequency: 140,
                gain: configuration.outputProfile.boomCutDB,
                sampleRate: configuration.sampleRate
            )
        } else {
            boomCut = nil
        }
        return BuiltCoefficients(
            equalizer: equalizer,
            preamp: preamp,
            loudnessGain: loudnessGain,
            compressorThreshold: 0.6,
            compressorRatio: 3.0,
            compressorMakeupGain: configuration.loudnessNormEnabled ? 1.5 : 1.2,
            boomCut: boomCut,
            sideHighPass: Self.highPassCoefficients(
                frequency: SpatialAudioDSP.sideHighPassFrequency,
                sampleRate: configuration.sampleRate
            )
        )
    }

    /// Access only while holding `lock`.
    private func apply(_ built: BuiltCoefficients) {
        coefficients = built.equalizer
        preamp = built.preamp
        loudnessGain = built.loudnessGain
        compressorThreshold = built.compressorThreshold
        compressorRatio = built.compressorRatio
        compressorMakeupGain = built.compressorMakeupGain
        boomCutCoefficients = built.boomCut
        sideHighPassCoefficients = built.sideHighPass
        envelope = 0
    }

    private static func peakingCoefficients(
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

    private static func lowShelfCoefficients(
        frequency: Double,
        gain: Double,
        sampleRate: Double
    ) -> Coefficients {
        let safeFrequency = min(max(frequency, 20), sampleRate * 0.45)
        let amplitude = pow(10, gain / 40)
        let omega = 2 * Double.pi * safeFrequency / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let beta = sqrt(amplitude) / 1.0
        let a0 = (amplitude + 1)
            + (amplitude - 1) * cosine
            + beta * sine
        return Coefficients(
            b0: Float(
                (
                    amplitude
                        * (
                            (amplitude + 1)
                                - (amplitude - 1) * cosine
                                + beta * sine
                        )
                ) / a0
            ),
            b1: Float(
                (
                    2 * amplitude
                        * ((amplitude - 1) - (amplitude + 1) * cosine)
                ) / a0
            ),
            b2: Float(
                (
                    amplitude
                        * (
                            (amplitude + 1)
                                - (amplitude - 1) * cosine
                                - beta * sine
                        )
                ) / a0
            ),
            a1: Float(
                (-2 * ((amplitude - 1) + (amplitude + 1) * cosine)) / a0
            ),
            a2: Float(
                (
                    (amplitude + 1)
                        + (amplitude - 1) * cosine
                        - beta * sine
                ) / a0
            )
        )
    }

    private static func highPassCoefficients(
        frequency: Double,
        sampleRate: Double
    ) -> Coefficients {
        let safeFrequency = min(max(frequency, 20), sampleRate * 0.45)
        let omega = 2 * Double.pi * safeFrequency / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let alpha = sine / (2 * (1 / sqrt(2.0)))
        let a0 = 1 + alpha
        return Coefficients(
            b0: Float(((1 + cosine) / 2) / a0),
            b1: Float((-(1 + cosine)) / a0),
            b2: Float(((1 + cosine) / 2) / a0),
            a1: Float((-2 * cosine) / a0),
            a2: Float((1 - alpha) / a0)
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
