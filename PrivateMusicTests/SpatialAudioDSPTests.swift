import XCTest
@testable import PrivateMusic

final class SpatialAudioDSPTests: XCTestCase {
    func testZeroIntensityPreservesStereoSamples() {
        let output = SpatialAudioDSP.process(
            left: 0.42,
            right: -0.18,
            intensity: 0
        )

        XCTAssertEqual(output.left, 0.42, accuracy: 0.000_001)
        XCTAssertEqual(output.right, -0.18, accuracy: 0.000_001)
    }

    func testSpatialAudioWidensSideToCenterRatio() {
        let left: Float = 0.4
        let right: Float = 0.1
        let output = SpatialAudioDSP.process(
            left: left,
            right: right,
            intensity: 1
        )

        let inputRatio = abs(left - right) / abs(left + right)
        let outputRatio =
            abs(output.left - output.right)
            / abs(output.left + output.right)
        XCTAssertGreaterThan(
            outputRatio,
            inputRatio
        )
    }

    func testMonoSignalRemainsCenteredWithoutClipping() {
        let output = SpatialAudioDSP.process(
            left: 0.35,
            right: 0.35,
            intensity: 1
        )

        XCTAssertEqual(output.left, output.right, accuracy: 0.000_001)
        XCTAssertGreaterThan(output.left, 0)
        XCTAssertLessThan(output.left, 0.35)
    }

    func testWideningPreventsClipping() {
        let output = SpatialAudioDSP.process(
            left: 1,
            right: -1,
            intensity: 1
        )

        XCTAssertLessThanOrEqual(abs(output.left), 1)
        XCTAssertLessThanOrEqual(abs(output.right), 1)
        XCTAssertTrue(output.left.isFinite)
        XCTAssertTrue(output.right.isFinite)
    }

    func testWideningRemainsLinearNearPeakLevel() {
        let quiet = SpatialAudioDSP.process(
            left: 0.4,
            right: -0.4,
            intensity: 1
        )
        let loud = SpatialAudioDSP.process(
            left: 0.8,
            right: -0.8,
            intensity: 1
        )

        XCTAssertEqual(loud.left, quiet.left * 2, accuracy: 0.000_001)
        XCTAssertEqual(loud.right, quiet.right * 2, accuracy: 0.000_001)
    }

    func testSpatialAudioAloneRequiresProcessingTap() {
        let processor = EqualizerDSP()
        XCTAssertFalse(processor.requiresAudioTap)

        processor.update(
            enabled: false,
            gains: EqualizerPreset.flat.gains,
            preamp: 0,
            spatialAudio: true
        )

        XCTAssertTrue(processor.requiresAudioTap)
        XCTAssertFalse(processor.isEnabled)
    }

    func testSpatialAndEqualizerKeepLocalDecodeForAllSessionRoutes() {
        // Local decode is what lets the MTAudioProcessingTap reach speaker,
        // headphones, Bluetooth A2DP, and CarKit `.carAudio`.
        XCTAssertFalse(
            AudioProcessingRoutePolicy.allowsExternalPlayback(
                requiresAudioTap: true
            )
        )
        let processor = EqualizerDSP()
        processor.update(
            enabled: true,
            gains: EqualizerPreset.rock.gains,
            preamp: 0,
            spatialAudio: true,
            spatialIntensity: 0.5
        )
        XCTAssertTrue(processor.requiresAudioTap)
        XCTAssertFalse(
            AudioProcessingRoutePolicy.allowsExternalPlayback(
                requiresAudioTap: processor.requiresAudioTap
            )
        )
    }

    func testFlatEqualizerDoesNotInstallProcessingTap() {
        let processor = EqualizerDSP()
        processor.update(
            enabled: true,
            gains: EqualizerPreset.flat.gains,
            preamp: 0,
            spatialAudio: false
        )
        XCTAssertFalse(processor.requiresAudioTap)
        XCTAssertTrue(
            AudioProcessingRoutePolicy.allowsExternalPlayback(
                requiresAudioTap: processor.requiresAudioTap
            )
        )

        processor.update(
            enabled: true,
            gains: EqualizerPreset.flat.gains,
            preamp: 3,
            spatialAudio: false
        )
        XCTAssertTrue(processor.requiresAudioTap)
    }

    func testEqualizerAloneRequiresProcessingTapForEveryOutputRoute() {
        let processor = EqualizerDSP()
        processor.update(
            enabled: true,
            gains: EqualizerPreset.rock.gains,
            preamp: 0,
            spatialAudio: false
        )

        XCTAssertTrue(processor.requiresAudioTap)
        XCTAssertTrue(processor.isEnabled)
        XCTAssertFalse(
            AudioProcessingRoutePolicy.allowsExternalPlayback(
                requiresAudioTap: processor.requiresAudioTap
            )
        )
    }

    func testZeroIntensitySpatialAudioDoesNotInstallProcessingTap() {
        let processor = EqualizerDSP()
        processor.update(
            enabled: false,
            gains: EqualizerPreset.flat.gains,
            preamp: 0,
            spatialAudio: true,
            spatialIntensity: 0
        )
        XCTAssertFalse(processor.requiresAudioTap)

        processor.update(
            enabled: false,
            gains: EqualizerPreset.flat.gains,
            preamp: 0,
            spatialAudio: true,
            spatialIntensity: 0.05
        )
        XCTAssertTrue(processor.requiresAudioTap)
    }
}
