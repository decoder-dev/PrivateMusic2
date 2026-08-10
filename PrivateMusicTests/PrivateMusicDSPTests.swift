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
}
