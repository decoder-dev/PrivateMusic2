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

    func testSpatialAudioWidensSideSignalAndPreservesCenter() {
        let left: Float = 0.4
        let right: Float = 0.1
        let output = SpatialAudioDSP.process(
            left: left,
            right: right,
            intensity: 1
        )

        XCTAssertGreaterThan(
            abs(output.left - output.right),
            abs(left - right)
        )
        XCTAssertEqual(
            output.left + output.right,
            left + right,
            accuracy: 0.000_001
        )
    }

    func testMonoSignalRemainsCentered() {
        let output = SpatialAudioDSP.process(
            left: 0.35,
            right: 0.35,
            intensity: 1
        )

        XCTAssertEqual(output.left, 0.35, accuracy: 0.000_001)
        XCTAssertEqual(output.right, 0.35, accuracy: 0.000_001)
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
}
