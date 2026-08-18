import XCTest
@testable import PrivateMusic

final class MixArtworkFallbackTests: XCTestCase {
    private func makeMix(
        id: String,
        isSocial: Bool = false,
        curator: MixCurator? = nil
    ) -> MusicMix {
        MusicMix(
            id: id,
            title: "Mix",
            subtitle: "",
            artworkURL: nil,
            isSocial: isSocial,
            curator: curator
        )
    }

    /// Selena's own mix is assembled locally and never carries a cover, so
    /// its generated one has to read as the station the listener already
    /// sees on Home — not as a generic card.
    func testSelenaMixDrawsAsTheStation() {
        XCTAssertEqual(
            MixArtworkFallback.role(for: .common),
            .station
        )
        XCTAssertEqual(MixArtworkFallback.symbol(for: .common), "sparkles")
    }

    func testFriendMixDrawsAsAnArtistSurface() {
        let curator = MixCurator(
            id: "7",
            displayName: "Аня",
            photoURL: nil
        )
        let mix = makeMix(id: "friend-7", curator: curator)

        XCTAssertEqual(MixArtworkFallback.role(for: mix), .artist)
        XCTAssertEqual(
            MixArtworkFallback.symbol(for: mix),
            "person.2.wave.2.fill"
        )
    }

    /// A curator VK sent with no usable name is not a friend mix — it must
    /// not claim the artist surface on an empty display name.
    func testUnusableCuratorFallsBackToThePlainMixSurface() {
        let blank = MixCurator(id: "0", displayName: "   ", photoURL: nil)
        let mix = makeMix(id: "vk-1", curator: blank)

        XCTAssertEqual(MixArtworkFallback.role(for: mix), .mix)
    }

    func testOrdinaryVKMixDrawsAsAMix() {
        let mix = makeMix(id: "vk-42")

        XCTAssertEqual(MixArtworkFallback.role(for: mix), .mix)
        XCTAssertEqual(
            MixArtworkFallback.symbol(for: mix),
            "square.stack.fill"
        )
    }

    /// Every role the fallback can pick has to resolve to a fill that white
    /// glyph on top stays readable against, or the generated cover is worse
    /// than the missing image it replaced.
    func testEveryFallbackRoleResolvesToALegibleSurface() {
        let curator = MixCurator(id: "1", displayName: "A", photoURL: nil)
        let mixes: [MusicMix] = [
            .common,
            makeMix(id: "friend", curator: curator),
            makeMix(id: "plain")
        ]
        for mix in mixes {
            let role = MixArtworkFallback.role(for: mix)
            let surface = BubblePalette.surface(role, tint: nil)
            XCTAssertLessThan(
                surface.luminance,
                BubblePalette.surfaceLuminanceCeiling + 0.001
            )
            XCTAssertGreaterThan(surface.luminance, 0.05)
        }
    }
}
