import XCTest
@testable import PrivateMusic

private struct StubPlay: HomeStagePlayable {
    let stageArtist: String
}

@MainActor
final class HomeStageContextTests: XCTestCase {
    private func mix(
        _ id: String,
        title: String,
        curator: MixCurator? = nil
    ) -> MusicMix {
        MusicMix(
            id: id,
            title: title,
            subtitle: "",
            artworkURL: nil,
            curator: curator
        )
    }

    func testStationAlwaysLeadsEvenWithNothingElse() {
        let contexts = HomeStageContextBuilder.build(
            mixes: [],
            recentArtists: [],
            selectedMood: .any,
            stationTitle: "Селена"
        )

        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.kind, .station)
        XCTAssertEqual(contexts.first?.name, "Селена")
    }

    /// Showing all five moods would push the mixes and the recent artists
    /// off the rail, so only a mood the listener actually picked appears.
    func testOnlyTheSelectedMoodBecomesABubble() {
        let none = HomeStageContextBuilder.build(
            mixes: [],
            recentArtists: [],
            selectedMood: .any,
            stationTitle: "Селена"
        )
        XCTAssertFalse(none.contains { $0.kind == .vibe })

        let picked = HomeStageContextBuilder.build(
            mixes: [],
            recentArtists: [],
            selectedMood: .energetic,
            stationTitle: "Селена"
        )
        let vibe = picked.first { $0.kind == .vibe }
        XCTAssertEqual(vibe?.mood, .energetic)
    }

    func testOrderPutsArtistsAheadOfCatalogMixes() {
        let contexts = HomeStageContextBuilder.build(
            mixes: [mix("m1", title: "В дорогу")],
            recentArtists: ["Owar1"],
            selectedMood: .calm,
            stationTitle: "Селена"
        )

        XCTAssertEqual(
            contexts.map(\.kind),
            [.station, .vibe, .artist, .mix]
        )
    }

    /// A mix whose title repeats an artist bubble would render as two
    /// identical circles side by side.
    func testDuplicateNamesCollapse() {
        let contexts = HomeStageContextBuilder.build(
            mixes: [mix("m1", title: "owar1")],
            recentArtists: ["Owar1"],
            selectedMood: .any,
            stationTitle: "Селена"
        )

        XCTAssertEqual(contexts.filter { $0.name.lowercased() == "owar1" }.count, 1)
    }

    func testRailIsCapped() {
        let mixes = (0..<20).map { mix("m\($0)", title: "Микс \($0)") }
        let contexts = HomeStageContextBuilder.build(
            mixes: mixes,
            recentArtists: ["A", "B", "C"],
            selectedMood: .love,
            stationTitle: "Селена"
        )

        XCTAssertEqual(contexts.count, HomeStageContextBuilder.limit)
    }

    func testCuratorPhotoBecomesTheBubbleAvatar() {
        let photo = URL(string: "https://example.com/a.jpg")
        let contexts = HomeStageContextBuilder.build(
            mixes: [
                mix(
                    "m1",
                    title: "Вместе",
                    curator: MixCurator(
                        id: "1",
                        displayName: "Аня",
                        photoURL: photo
                    )
                )
            ],
            recentArtists: [],
            selectedMood: .any,
            stationTitle: "Селена"
        )

        XCTAssertEqual(contexts.last?.avatarURL, photo)
    }

    func testBlankNamesNeverBecomeBubbles() {
        let contexts = HomeStageContextBuilder.build(
            mixes: [mix("m1", title: "   ")],
            recentArtists: ["", "  "],
            selectedMood: .any,
            stationTitle: "Селена"
        )

        XCTAssertEqual(contexts.map(\.kind), [.station])
    }

    /// Looping one album all evening should not fill the rail with the
    /// same face repeated.
    func testRecentArtistsAreDeduplicatedInPlayOrder() {
        let artists = HomeStageContextBuilder.recentArtists(
            from: [
                StubPlay(stageArtist: "Owar1"),
                StubPlay(stageArtist: "owar1"),
                StubPlay(stageArtist: "Три дня дождя"),
                StubPlay(stageArtist: "Owar1"),
                StubPlay(stageArtist: "Mad Jozef")
            ]
        )

        XCTAssertEqual(artists, ["Owar1", "Три дня дождя", "Mad Jozef"])
    }

    func testMonogramSurvivesAnEmptyName() {
        let context = HomeStageContext(
            id: "x",
            kind: .mix,
            name: "",
            avatarURL: nil,
            mixID: nil,
            mood: nil
        )

        XCTAssertEqual(context.monogram, "?")
    }
}

@MainActor
final class HomeStageMetricsTests: XCTestCase {
    /// 320 is an SE in portrait, 430 a Pro Max; the stage has to stay
    /// inside one screen on the first and not look sparse on the second.
    private let widths: [CGFloat] = [320, 375, 393, 430]

    func testHeadlineStaysWithinItsBounds() {
        for width in widths {
            let size = HomeStageMetrics.artistFontSize(for: width)
            XCTAssertGreaterThanOrEqual(size, 32)
            XCTAssertLessThanOrEqual(size, 48)
        }
    }

    /// An iPhone SE is the smallest device iOS 17 runs on: 667 pt tall,
    /// leaving roughly 520 pt between the status bar and the dock. The
    /// stage has to land inside that with a single-line artist name — a
    /// two-line name pushes it a little past, which is fine, Home
    /// scrolls. What is not fine is opening on a stage that never fits.
    func testStageFitsOneScreenOnAnSE() {
        let width: CGFloat = 375
        let height =
            HomeStageMetrics.artistFontSize(for: width)
            + HomeStageMetrics.artworkSize(for: width)
            + HomeStageMetrics.controlHeight(for: width)
            + HomeStageMetrics.railHeight(for: width)
            + HomeStageViewPadding.total

        XCTAssertLessThan(height, 520)
    }

    /// Neighbouring bubbles must never match, or the row reads as a
    /// carousel of circles instead of bubbles.
    func testAdjacentBubblesDiffer() {
        for width in widths {
            for index in 0..<HomeStageContextBuilder.limit - 1 {
                XCTAssertNotEqual(
                    HomeStageMetrics.bubbleSize(for: width, index: index),
                    HomeStageMetrics.bubbleSize(
                        for: width,
                        index: index + 1
                    )
                )
            }
        }
    }

    /// The rail is a window shorter than the bubbles so they are all cut
    /// by one line — but it must still leave room for the avatar that
    /// straddles the rim, or the faces get sliced off at the top.
    func testRailClipsBubblesButNotAvatars() {
        for width in widths {
            let rail = HomeStageMetrics.railHeight(for: width)
            let tallest = HomeStageMetrics.bubbleSize(for: width)
            let overhang = HomeStageMetrics.avatarOverhang(for: width)

            XCTAssertLessThan(rail, tallest + overhang)
            XCTAssertGreaterThan(rail, overhang + tallest * 0.6)
        }
    }
}
