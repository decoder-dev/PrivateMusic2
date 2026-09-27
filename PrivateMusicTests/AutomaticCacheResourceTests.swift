import XCTest
@testable import PrivateMusic

final class AutomaticCacheResourceTests: XCTestCase {
    func testCachingRequiresConsentAndUnmeteredNetwork() {
        for enabled in [false, true] {
            for sharing in [false, true] {
                for unmetered in [false, true] {
                    XCTAssertEqual(PlaybackResourcePolicy.allowAutomaticCaching(
                        enabled: enabled, sharing: sharing, unmeteredNetwork: unmetered,
                        lowPowerMode: false, thermalState: .nominal
                    ), enabled && !sharing && unmetered)
                }
            }
        }
    }

    func testOptionalDownloadsStopAtModerateHeatAndInLowPowerMode() {
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                XCTAssertEqual(PlaybackResourcePolicy.allowAutomaticCaching(
                    enabled: true, sharing: false, unmeteredNetwork: true,
                    lowPowerMode: lowPower, thermalState: thermal
                ), !lowPower && thermal == .nominal)
            }
        }
    }

    @MainActor func testUntrustedDurationCannotOverflowCacheEstimate() {
        for duration in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude] {
            XCTAssertEqual(PlaybackResourcePolicy.automaticCacheSizeEstimate(duration: duration),
                           OfflineTrackStore.maximumTrackSize)
        }
        XCTAssertEqual(PlaybackResourcePolicy.automaticCacheSizeEstimate(duration: 0), 5_000_000)
        XCTAssertEqual(PlaybackResourcePolicy.automaticCacheSizeEstimate(duration: 180), 7_200_000)
    }
}
