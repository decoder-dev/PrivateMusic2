import XCTest
@testable import PrivateMusic

final class VPNHelpPolicyTests: XCTestCase {
    func testWrappedPlayerNetworkErrorsOfferHelpWithoutTreatingEveryPlaybackErrorAsVPN() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        XCTAssertTrue(VPNHelpPolicy.shouldOfferHelp(for: error))
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: NSError(domain: "AVFoundationErrorDomain", code: -11800)))
    }

    func testNetworkFailuresOfferTroubleshootingWithoutClaimingDetection() {
        XCTAssertTrue(VPNHelpPolicy.shouldOfferHelp(for: APIError.timedOut))
        XCTAssertTrue(VPNHelpPolicy.shouldOfferHelp(for: APIError.transport("Connection failed")))
        let codes: [URLError.Code] = [.timedOut, .cannotFindHost, .cannotConnectToHost,
                                     .dnsLookupFailed, .networkConnectionLost, .secureConnectionFailed]
        for code in codes {
            XCTAssertTrue(VPNHelpPolicy.shouldOfferHelp(for: URLError(code)))
        }
    }

    func testExpiredSessionAndContentRestrictionsDoNotSuggestVPN() {
        let errors: [APIError] = [.unauthorized, .server(code: 5, message: "Expired session"),
                                 .server(code: 15, message: "Unavailable"),
                                 .server(code: 429, message: "Rate limited"),
                                 .server(code: 503, message: "Maintenance")]
        for error in errors {
            XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: error))
        }
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: VKWebAuthError.rejected("Session rejected")))
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: VKWebAuthError.noSession))
    }

    func testOfflineCancellationAndMalformedResponsesDoNotSuggestVPN() {
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: APIError.offline))
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: URLError(.notConnectedToInternet)))
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: URLError(.cancelled)))
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: CancellationError()))
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: APIError.invalidResponse))
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: APIError.decoding("Invalid JSON")))
        XCTAssertFalse(VPNHelpPolicy.shouldOfferHelp(for: URLError(.serverCertificateUntrusted)))
    }
}
