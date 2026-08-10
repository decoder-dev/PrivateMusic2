import XCTest
@testable import PrivateMusic

final class PrivateMusicDSPTests: XCTestCase {
    func testBiquadIdentityPassesSampleThroughNearlyUnchanged() {
        // b0=1, others 0 → y[n] = x[n]
        var coeffs = PMBiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        var state: [Float] = [0, 0, 0, 0]
        let output = pm_biquad_process(0.25, &coeffs, &state)
        XCTAssertEqual(output, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(state[0], 0.25, accuracy: 0.000_001)
        XCTAssertEqual(state[2], 0.25, accuracy: 0.000_001)
    }

    func testEQProcessChannelAppliesPreampAndClamps() {
        var samples: [Float] = [0.8, 0.8, 0.8, 0.8]
        var envelope: Float = 0
        samples.withUnsafeMutableBufferPointer { buffer in
            pm_eq_process_channel(
                buffer.baseAddress,
                4,
                1,
                nil,
                0,
                nil,
                2.0,
                false,
                0.5,
                4,
                1,
                &envelope,
                false,
                1
            )
        }
        for sample in samples {
            XCTAssertEqual(sample, 1.0, accuracy: 0.000_001)
        }
    }

    func testSpatialWidenMatchesSwiftWrapper() {
        let left: Float = 0.4
        let right: Float = -0.2
        let viaSwift = SpatialAudioDSP.process(
            left: left,
            right: right,
            intensity: 1
        )
        var outLeft: Float = 0
        var outRight: Float = 0
        pm_spatial_widen(left, right, 1, 0, false, &outLeft, &outRight)
        XCTAssertEqual(viaSwift.left, outLeft, accuracy: 0.000_001)
        XCTAssertEqual(viaSwift.right, outRight, accuracy: 0.000_001)
    }

    // MARK: - Buffer hot paths

    func testBiquadChannelMatchesRepeatedSingleSampleCalls() {
        var coeffs = PMBiquadCoeffs(
            b0: 0.5,
            b1: 0.2,
            b2: -0.1,
            a1: -0.3,
            a2: 0.15
        )
        let input: [Float] = [0.4, -0.7, 0.9, 0.1, -0.2, 0.6, -0.95, 0.33]

        var expected: [Float] = []
        var referenceState: [Float] = [0, 0, 0, 0]
        for sample in input {
            let value = pm_biquad_process(sample, &coeffs, &referenceState)
            expected.append(min(max(value, -1), 1))
        }

        var samples = input
        var state: [Float] = [0, 0, 0, 0]
        samples.withUnsafeMutableBufferPointer { buffer in
            pm_biquad_process_channel(
                buffer.baseAddress,
                Int32(buffer.count),
                1,
                &coeffs,
                &state,
                true
            )
        }

        for (actual, want) in zip(samples, expected) {
            XCTAssertEqual(actual, want, accuracy: 0.000_01)
        }
        for (actual, want) in zip(state, referenceState) {
            XCTAssertEqual(actual, want, accuracy: 0.000_01)
        }
    }

    func testBiquadChannelWalksOnlyItsOwnInterleavedChannel() {
        var coeffs = PMBiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        var samples: [Float] = [4, 0.2, -4, 0.4, 0.5, 0.6]
        var state: [Float] = [0, 0, 0, 0]
        samples.withUnsafeMutableBufferPointer { buffer in
            pm_biquad_process_channel(
                buffer.baseAddress,
                3,
                2,
                &coeffs,
                &state,
                true
            )
        }
        XCTAssertEqual(samples[0], 1, accuracy: 0.000_001)
        XCTAssertEqual(samples[2], -1, accuracy: 0.000_001)
        XCTAssertEqual(samples[1], 0.2, accuracy: 0.000_001)
        XCTAssertEqual(samples[3], 0.4, accuracy: 0.000_001)
        XCTAssertEqual(samples[5], 0.6, accuracy: 0.000_001)
    }

    func testSpatialPlanarMatchesPerSampleWidenWithSideHighPass() {
        var highPass = PMBiquadCoeffs(
            b0: 0.9,
            b1: -1.8,
            b2: 0.9,
            a1: -1.7,
            a2: 0.75
        )
        let intensity: Float = 0.6
        let inputLeft: [Float] = [0.5, -0.25, 0.75, 0.1, -0.6]
        let inputRight: [Float] = [0.2, 0.4, -0.3, 0.9, 0.05]

        var expectedLeft: [Float] = []
        var expectedRight: [Float] = []
        var referenceState: [Float] = [0, 0, 0, 0]
        for index in inputLeft.indices {
            let side = (inputLeft[index] - inputRight[index]) * 0.5
            let filtered = pm_biquad_process(side, &highPass, &referenceState)
            var outLeft: Float = 0
            var outRight: Float = 0
            pm_spatial_widen(
                inputLeft[index],
                inputRight[index],
                intensity,
                filtered,
                true,
                &outLeft,
                &outRight
            )
            expectedLeft.append(outLeft)
            expectedRight.append(outRight)
        }

        var left = inputLeft
        var right = inputRight
        var state: [Float] = [0, 0, 0, 0]
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                pm_spatial_process_planar(
                    leftBuffer.baseAddress,
                    rightBuffer.baseAddress,
                    Int32(leftBuffer.count),
                    intensity,
                    &highPass,
                    true,
                    &state
                )
            }
        }

        for (actual, want) in zip(left, expectedLeft) {
            XCTAssertEqual(actual, want, accuracy: 0.000_01)
        }
        for (actual, want) in zip(right, expectedRight) {
            XCTAssertEqual(actual, want, accuracy: 0.000_01)
        }
        for (actual, want) in zip(state, referenceState) {
            XCTAssertEqual(actual, want, accuracy: 0.000_01)
        }
    }

    func testSpatialInterleavedMatchesPlanar() {
        var highPass = PMBiquadCoeffs(
            b0: 0.9,
            b1: -1.8,
            b2: 0.9,
            a1: -1.7,
            a2: 0.75
        )
        var left: [Float] = [0.5, -0.25, 0.75, 0.1]
        var right: [Float] = [0.2, 0.4, -0.3, 0.9]
        var interleaved: [Float] = [
            0.5, 0.2, -0.25, 0.4, 0.75, -0.3, 0.1, 0.9
        ]
        var planarState: [Float] = [0, 0, 0, 0]
        var interleavedState: [Float] = [0, 0, 0, 0]

        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                pm_spatial_process_planar(
                    leftBuffer.baseAddress,
                    rightBuffer.baseAddress,
                    4,
                    0.45,
                    &highPass,
                    true,
                    &planarState
                )
            }
        }
        interleaved.withUnsafeMutableBufferPointer { buffer in
            pm_spatial_process_interleaved(
                buffer.baseAddress,
                4,
                2,
                0.45,
                &highPass,
                true,
                &interleavedState
            )
        }

        for index in left.indices {
            XCTAssertEqual(
                interleaved[index * 2],
                left[index],
                accuracy: 0.000_01
            )
            XCTAssertEqual(
                interleaved[index * 2 + 1],
                right[index],
                accuracy: 0.000_01
            )
        }
    }

    func testSpatialProcessingIsANoOpAtZeroIntensity() {
        var highPass = PMBiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        var left: [Float] = [0.5, 0.25]
        var right: [Float] = [-0.5, 0.75]
        var state: [Float] = [0, 0, 0, 0]
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                pm_spatial_process_planar(
                    leftBuffer.baseAddress,
                    rightBuffer.baseAddress,
                    2,
                    0,
                    &highPass,
                    true,
                    &state
                )
            }
        }
        XCTAssertEqual(left, [0.5, 0.25])
        XCTAssertEqual(right, [-0.5, 0.75])
        XCTAssertEqual(state, [0, 0, 0, 0])
    }

    func testSpatialWithoutSideHighPassMatchesUnfilteredWiden() {
        var highPass = PMBiquadCoeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        var expectedLeft: Float = 0
        var expectedRight: Float = 0
        pm_spatial_widen(0.5, -0.5, 0.8, 0, false, &expectedLeft, &expectedRight)

        var left: [Float] = [0.5]
        var right: [Float] = [-0.5]
        var state: [Float] = [0, 0, 0, 0]
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                pm_spatial_process_planar(
                    leftBuffer.baseAddress,
                    rightBuffer.baseAddress,
                    1,
                    0.8,
                    &highPass,
                    false,
                    &state
                )
            }
        }
        XCTAssertEqual(left[0], expectedLeft, accuracy: 0.000_01)
        XCTAssertEqual(right[0], expectedRight, accuracy: 0.000_01)
        XCTAssertEqual(state, [0, 0, 0, 0], "skipping the filter leaves state")
    }
}
