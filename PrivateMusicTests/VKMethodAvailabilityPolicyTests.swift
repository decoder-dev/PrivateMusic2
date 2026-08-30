import XCTest
@testable import PrivateMusic

/// From a device log: opening an artist always began with
/// `audio.getAlbumsByArtist` answering `vk=3 Unknown method passed`, then
/// `catalog.getAudioArtist` succeeding with the albums. The fallback works,
/// so the only cost is a request that could never succeed — on every
/// artist page, on a metered connection.
final class VKMethodAvailabilityPolicyTests: XCTestCase {
    func testUnknownMethodIsTakenAsPermanent() {
        XCTAssertTrue(
            VKMethodAvailabilityPolicy.isPermanentlyUnavailable(
                code: VKMethodAvailabilityPolicy.unknownMethodCode
            )
        )
        XCTAssertEqual(VKMethodAvailabilityPolicy.unknownMethodCode, 3)
    }

    /// The codes that mean "try again" must not be remembered, or one bad
    /// minute would disable a working method for the rest of the session.
    /// 6 and 10 are the rate limit and VK's own internal error, both of
    /// which `RequestRetryPolicy.transient` already retries; 5 is an
    /// expired token, which the session exchange handles.
    func testTransientAndAuthCodesAreNotRemembered() {
        for code in [5, 6, 10, 14, 15, 100, 500] {
            XCTAssertFalse(
                VKMethodAvailabilityPolicy.isPermanentlyUnavailable(
                    code: code
                ),
                "vk=\(code) must stay retryable"
            )
        }
    }

    func testSuccessIsNotMistakenForAMissingMethod() {
        XCTAssertFalse(
            VKMethodAvailabilityPolicy.isPermanentlyUnavailable(code: 0)
        )
    }
}
