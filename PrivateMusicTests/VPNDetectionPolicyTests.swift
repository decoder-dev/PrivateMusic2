import XCTest
@testable import PrivateMusic

final class VPNDetectionPolicyTests: XCTestCase {
    func testActiveAddressedTunnelProducesHint() {
        XCTAssertTrue(VPNDetectionPolicy.isTunnelHint(name: "utun4", address: "10.7.0.1", isUp: true))
        XCTAssertTrue(VPNDetectionPolicy.isTunnelHint(name: "ipsec0", address: "fd00::2", isUp: true))
    }

    func testSystemLinkLocalAndInactiveTunnelsDoNotProduceHint() {
        XCTAssertFalse(VPNDetectionPolicy.isTunnelHint(name: "utun0", address: "fe80::1%utun0", isUp: true))
        XCTAssertFalse(VPNDetectionPolicy.isTunnelHint(name: "utun0", address: "169.254.1.2", isUp: true))
        XCTAssertFalse(VPNDetectionPolicy.isTunnelHint(name: "utun4", address: "10.7.0.1", isUp: false))
        XCTAssertFalse(VPNDetectionPolicy.isTunnelHint(name: "utun4", address: "::", isUp: true))
    }

    func testOrdinaryNetworkAndLoopbackDoNotProduceHint() {
        XCTAssertFalse(VPNDetectionPolicy.isTunnelHint(name: "en0", address: "192.168.1.2", isUp: true))
        XCTAssertFalse(VPNDetectionPolicy.isTunnelHint(name: "pdp_ip0", address: "10.0.0.2", isUp: true))
        XCTAssertFalse(VPNDetectionPolicy.isTunnelHint(name: "tun0", address: "127.0.0.1", isUp: true))
    }
}
