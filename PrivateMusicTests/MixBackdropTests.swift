import XCTest
@testable import PrivateMusic

final class MixBackdropTests: XCTestCase {
    /// Same layer layout as the animation the official app ships for its
    /// smart mix: one gradient blob per corner plus two flat backgrounds.
    private let sample = """
    {"v":"5.0.1","layers":[
      {"nm":"bottom_left","shapes":[{"it":[{"ty":"gr"},{"ty":"gf","g":{"p":2,"k":{"a":0,"k":[0,0.996,0.373,0.314,1,0.996,0.373,0.314]}}}]}]},
      {"nm":"bottom_right","shapes":[{"it":[{"ty":"gf","g":{"p":2,"k":{"a":0,"k":[0,0.922,0.416,0.157,1,0.922,0.416,0.157]}}}]}]},
      {"nm":"top_right","shapes":[{"it":[{"ty":"gf","g":{"p":2,"k":{"a":0,"k":[0,1,0.722,0.161,1,1,0.722,0.161]}}}]}]},
      {"nm":"top_left","shapes":[{"it":[{"ty":"gf","g":{"p":2,"k":{"a":0,"k":[0,1,0.851,0.102,1,1,0.851,0.102]}}}]}]},
      {"nm":"top_bg","shapes":[{"it":[{"ty":"fl","c":{"a":0,"k":[0.922,0.416,0.157,1]}}]}]}
    ]}
    """

    func testCornersAreReadByLayerName() throws {
        let palette = try XCTUnwrap(
            MixBackdropParser.palette(fromLottie: Data(sample.utf8))
        )
        XCTAssertEqual(palette.topLeading.green, 0.851, accuracy: 0.001)
        XCTAssertEqual(palette.topTrailing.green, 0.722, accuracy: 0.001)
        XCTAssertEqual(palette.bottomLeading.blue, 0.314, accuracy: 0.001)
        XCTAssertEqual(palette.bottomTrailing.red, 0.922, accuracy: 0.001)
    }

    func testNonLottieDataIsRejected() {
        XCTAssertNil(MixBackdropParser.palette(fromLottie: Data("nope".utf8)))
        XCTAssertNil(MixBackdropParser.palette(fromLottie: Data("{}".utf8)))
    }

    func testByteColoursAreNormalised() throws {
        let json = """
        {"layers":[{"nm":"top_left","shapes":[{"ty":"fl","c":{"k":[255,128,0,1]}}]}]}
        """
        let palette = try XCTUnwrap(
            MixBackdropParser.palette(fromLottie: Data(json.utf8))
        )
        XCTAssertEqual(palette.topLeading.red, 1, accuracy: 0.001)
        XCTAssertEqual(palette.topLeading.green, 128 / 255, accuracy: 0.001)
        // Missing corners reuse the colours that exist.
        XCTAssertEqual(palette.bottomTrailing, palette.topLeading)
    }
}
