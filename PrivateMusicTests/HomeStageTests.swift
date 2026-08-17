import XCTest
@testable import PrivateMusic

private struct StubPlay: HomeStagePlayable {
    let stageTrack: Track
}

private func makeTrack(
    id: Int,
    title: String,
    artist: String
) -> Track {
    Track(
        trackID: id,
        ownerID: 1,
        title: title,
        artist: artist,
        duration: 180,
        streamURL: nil,
        artworkURL: nil,
        isHQ: false
    )
}

private func makeMix(
    _ id: String,
    title: String,
    subtitle: String = "",
    curator: MixCurator? = nil
) -> MusicMix {
    MusicMix(
        id: id,
        title: title,
        subtitle: subtitle,
        artworkURL: nil,
        curator: curator
    )
}

@MainActor
final class HomeStageContextTests: XCTestCase {
    func testStationAlwaysLeadsEvenWithNothingElse() {
        let contexts = HomeStageContextBuilder.build(
            mixes: [],
            recentArtists: [],
            selectedMood: .any,
            stationTitle: "Селена"
        )

        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.kind, .station)
        XCTAssertEqual(contexts.first?.priority, .primary)
    }

    /// All five moods would push the mixes and the recent artists off the
    /// rail, so only a mood the listener actually picked appears.
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
        XCTAssertEqual(picked.first { $0.kind == .vibe }?.mood, .energetic)
    }

    func testOrderPutsArtistsAheadOfCatalogMixes() {
        let contexts = HomeStageContextBuilder.build(
            mixes: [makeMix("m1", title: "В дорогу")],
            recentArtists: [HomeStageArtist(name: "Owar1", seed: nil)],
            selectedMood: .calm,
            stationTitle: "Селена"
        )

        XCTAssertEqual(
            contexts.map(\.kind),
            [.station, .vibe, .artist, .mix]
        )
    }

    /// Prominence has to come from what a context is. The builder used to
    /// call `priority(forPosition: contexts.count)`, which is exactly the
    /// positional sizing the system forbids.
    func testPriorityIsSemanticNotPositional() {
        XCTAssertEqual(
            BubblePriorityPolicy.priority(for: .station),
            .primary
        )
        XCTAssertEqual(BubblePriorityPolicy.priority(for: .vibe), .secondary)
        XCTAssertEqual(
            BubblePriorityPolicy.priority(for: .artist, rank: 0),
            .secondary
        )
        XCTAssertEqual(
            BubblePriorityPolicy.priority(for: .artist, rank: 2),
            .tertiary
        )
        XCTAssertEqual(BubblePriorityPolicy.priority(for: .mix), .tertiary)
    }

    /// The same context must keep its size wherever it lands in the rail.
    func testPriorityDoesNotDependOnArrayPosition() {
        let withMood = HomeStageContextBuilder.build(
            mixes: [makeMix("m1", title: "В дорогу")],
            recentArtists: [HomeStageArtist(name: "Owar1", seed: nil)],
            selectedMood: .energetic,
            stationTitle: "Селена"
        )
        let withoutMood = HomeStageContextBuilder.build(
            mixes: [makeMix("m1", title: "В дорогу")],
            recentArtists: [HomeStageArtist(name: "Owar1", seed: nil)],
            selectedMood: .any,
            stationTitle: "Селена"
        )

        // Dropping the mood shifts the artist one slot earlier; its size
        // must not change with it.
        XCTAssertEqual(
            withMood.first { $0.kind == .artist }?.priority,
            withoutMood.first { $0.kind == .artist }?.priority
        )
        XCTAssertEqual(
            withMood.first { $0.kind == .mix }?.priority,
            withoutMood.first { $0.kind == .mix }?.priority
        )
    }

    /// A mix whose title repeats an artist bubble would render as two
    /// identical circles side by side.
    func testDuplicateNamesCollapse() {
        let contexts = HomeStageContextBuilder.build(
            mixes: [makeMix("m1", title: "owar1")],
            recentArtists: [HomeStageArtist(name: "Owar1", seed: nil)],
            selectedMood: .any,
            stationTitle: "Селена"
        )

        XCTAssertEqual(
            contexts.filter { $0.name.lowercased() == "owar1" }.count,
            1
        )
    }

    func testRailIsCapped() {
        let mixes = (0..<20).map { makeMix("m\($0)", title: "Микс \($0)") }
        let contexts = HomeStageContextBuilder.build(
            mixes: mixes,
            recentArtists: [
                HomeStageArtist(name: "A", seed: nil),
                HomeStageArtist(name: "B", seed: nil)
            ],
            selectedMood: .love,
            stationTitle: "Селена"
        )

        XCTAssertEqual(contexts.count, HomeStageContextBuilder.limit)
    }

    func testBlankNamesNeverBecomeBubbles() {
        let contexts = HomeStageContextBuilder.build(
            mixes: [makeMix("m1", title: "   ")],
            recentArtists: [HomeStageArtist(name: "  ", seed: nil)],
            selectedMood: .any,
            stationTitle: "Селена"
        )

        XCTAssertEqual(contexts.map(\.kind), [.station])
    }

    func testCuratorPhotoBecomesTheBubbleAvatar() {
        let photo = URL(string: "https://example.com/a.jpg")
        let contexts = HomeStageContextBuilder.build(
            mixes: [
                makeMix(
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

    /// Tapping an artist used to launch a generic library mix, because the
    /// context carried nothing but a display string. It has to hold enough
    /// to start that specific artist.
    func testArtistContextCarriesEnoughToLaunchTheArtist() {
        let seed = makeTrack(id: 7, title: "Не надо", artist: "Owar1")
        let contexts = HomeStageContextBuilder.build(
            mixes: [],
            recentArtists: [HomeStageArtist(name: "Owar1", seed: seed)],
            selectedMood: .any,
            stationTitle: "Селена"
        )

        let artist = contexts.first { $0.kind == .artist }
        XCTAssertEqual(artist?.artist?.name, "Owar1")
        XCTAssertEqual(artist?.artist?.seed?.id, seed.id)
        XCTAssertNil(artist?.mixID, "artist must not resolve through a mix id")
    }

    /// An evening spent looping one album should not fill the rail with
    /// the same face, and the seed must stay the newest play.
    func testRecentArtistsDeduplicateAndKeepTheNewestSeed() {
        let newest = makeTrack(id: 1, title: "Не надо", artist: "Owar1")
        let artists = HomeStageContextBuilder.recentArtists(
            from: [
                StubPlay(stageTrack: newest),
                StubPlay(
                    stageTrack: makeTrack(
                        id: 2,
                        title: "Другой",
                        artist: "owar1"
                    )
                ),
                StubPlay(
                    stageTrack: makeTrack(
                        id: 3,
                        title: "Ласточка",
                        artist: "Три дня дождя"
                    )
                )
            ]
        )

        XCTAssertEqual(artists.map(\.name), ["Owar1", "Три дня дождя"])
        XCTAssertEqual(artists.first?.seed?.id, newest.id)
    }

    func testMonogramSurvivesAnEmptyName() {
        let context = HomeStageContext(
            id: "x",
            kind: .mix,
            name: "",
            priority: .tertiary,
            avatarURL: nil,
            mixID: nil,
            mood: nil,
            artist: nil
        )

        XCTAssertEqual(context.monogram, "?")
    }

    /// VoiceOver should hear one sentence per bubble, not image + kicker +
    /// name as three separate elements.
    func testBubbleExposesOneAccessibilitySentence() {
        let context = HomeStageContext(
            id: "artist-owar1",
            kind: .artist,
            name: "Owar1",
            priority: .secondary,
            avatarURL: nil,
            mixID: nil,
            mood: nil,
            artist: HomeStageArtist(name: "Owar1", seed: nil)
        )

        XCTAssertTrue(context.accessibilityLabel.contains("Owar1"))
        XCTAssertTrue(
            context.accessibilityLabel.contains(
                HomeStageContextKind.artist.kicker
            )
        )
        // The noun alone leaves the listener guessing whether tapping
        // opens a page or starts playing.
        XCTAssertTrue(
            context.accessibilityLabel.contains(
                HomeStageContextKind.artist.actionHint
            )
        )
    }

    /// VK sometimes hands back a multi-artist credit as one comma-joined
    /// string. The bubble's display name must fold it down rather than
    /// showing the run-on string a listener actually saw on device.
    func testMultiArtistCreditCollapsesToLeadPlusCount() {
        let context = HomeStageContext(
            id: "artist-skwlkr",
            kind: .artist,
            name: "SKWLKR, Lastfragment, Somebody Else",
            priority: .secondary,
            avatarURL: nil,
            mixID: nil,
            mood: nil,
            artist: HomeStageArtist(name: "SKWLKR", seed: nil)
        )

        XCTAssertFalse(context.displayName.contains(","))
        XCTAssertTrue(context.displayName.hasPrefix("SKWLKR"))
        XCTAssertTrue(context.displayName.contains("2"))
        // Accessibility must read the same short label, not the raw credit.
        XCTAssertFalse(context.accessibilityLabel.contains("Lastfragment"))
    }

    func testSingleArtistNameIsUnaffected() {
        let context = HomeStageContext(
            id: "artist-owar1",
            kind: .artist,
            name: "Owar1",
            priority: .secondary,
            avatarURL: nil,
            mixID: nil,
            mood: nil,
            artist: HomeStageArtist(name: "Owar1", seed: nil)
        )

        XCTAssertEqual(context.displayName, "Owar1")
    }
}

@MainActor
final class ArtistCreditDisplayTests: XCTestCase {
    func testTwoArtistsFoldIntoLeadPlusOne() {
        XCTAssertEqual(
            ArtistCreditDisplay.summarize("SKWLKR, Lastfragment"),
            L10n.format("home_stage.artist_plus_d0", "SKWLKR", 1)
        )
    }

    func testWhitespaceOnlySegmentsDoNotCountAsExtraArtists() {
        // A trailing comma or double comma from upstream data must not
        // turn one artist into "Name +1".
        XCTAssertEqual(
            ArtistCreditDisplay.summarize("Owar1,  ,"),
            "Owar1"
        )
    }

    func testSingleNameWithoutCommaPassesThrough() {
        XCTAssertEqual(ArtistCreditDisplay.summarize("Owar1"), "Owar1")
    }

    func testEmptyStringPassesThrough() {
        XCTAssertEqual(ArtistCreditDisplay.summarize(""), "")
    }

    /// The Hero must never show the bubble's "+N" shorthand — it needs the
    /// real name, joined the way a byline reads.
    func testReadableJoinsTwoArtistsWithAmpersand() {
        XCTAssertEqual(
            ArtistCreditDisplay.readable("SKWLKR, Lastfragment"),
            "SKWLKR & Lastfragment"
        )
    }

    func testReadableJoinsThreeArtistsWithCommasAndAFinalAmpersand() {
        XCTAssertEqual(
            ArtistCreditDisplay.readable("A, B, C"),
            "A, B & C"
        )
    }

    func testReadableNeverProducesTheCompactPlusNotation() {
        let readable = ArtistCreditDisplay.readable("SKWLKR, Lastfragment")
        XCTAssertFalse(readable.contains("+"))
    }

    func testReadableSingleNamePassesThrough() {
        XCTAssertEqual(ArtistCreditDisplay.readable("Owar1"), "Owar1")
    }

    func testReadableTrailingCommaCleansUpToTheSingleName() {
        XCTAssertEqual(ArtistCreditDisplay.readable("Owar1,  ,"), "Owar1")
    }

    func testReadableEmptyStringPassesThrough() {
        XCTAssertEqual(ArtistCreditDisplay.readable(""), "")
    }
}

@MainActor
final class HomeStagePresentationTests: XCTestCase {
    /// Idle used to show a play button, a large "Включить" pill and a
    /// disabled heart at once — three controls for one possible action.
    func testIdleShowsOneCallToActionAndNoHeart() {
        let idle = HomeStagePresentation.resolve(hasCurrentTrack: false)

        XCTAssertTrue(idle.showsCallToAction)
        XCTAssertFalse(idle.showsHeart)
        XCTAssertFalse(idle.showsTransportButton)
        XCTAssertFalse(idle.chipIsProminent)
        XCTAssertTrue(idle.showsRail, "contexts stay reachable when idle")
    }

    func testPlayingShowsTransportAndHeartButNoCallToAction() {
        let playing = HomeStagePresentation.resolve(hasCurrentTrack: true)

        XCTAssertFalse(playing.showsCallToAction)
        XCTAssertTrue(playing.showsHeart)
        XCTAssertTrue(playing.showsTransportButton)
        XCTAssertTrue(playing.chipIsProminent)
    }
}

@MainActor
final class MixMoodLaunchPolicyTests: XCTestCase {
    /// The bug this exists for: the mood bubble wrote
    /// `settings.mixMoodPreference` and then started the ordinary personal
    /// station, so «Активно» and «Спокойно» produced the same queue.
    func testMoodPicksItsOwnShelfRatherThanThePersonalStation() {
        let personal = makeMix(MusicMix.common.id, title: "Составлено Селеной")
        let energetic = makeMix("m1", title: "Энергичный драйв")
        let calm = makeMix("m2", title: "Спокойный вечер")

        XCTAssertEqual(
            MixMoodLaunchPolicy.resolve(
                mood: .energetic,
                in: [personal, energetic, calm]
            ),
            .mix(energetic)
        )
        XCTAssertEqual(
            MixMoodLaunchPolicy.resolve(
                mood: .calm,
                in: [personal, energetic, calm]
            ),
            .mix(calm)
        )
    }

    func testTwoDifferentMoodsDoNotResolveToTheSameQueue() {
        let mixes = [
            makeMix(MusicMix.common.id, title: "Составлено Селеной"),
            makeMix("m1", title: "Энергичный драйв"),
            makeMix("m2", title: "Спокойный вечер")
        ]

        XCTAssertNotEqual(
            MixMoodLaunchPolicy.resolve(mood: .energetic, in: mixes),
            MixMoodLaunchPolicy.resolve(mood: .calm, in: mixes)
        )
    }

    /// A shelf that merely looks like a mood shelf must never outrank one
    /// that actually names the mood asked for.
    func testANamedMoodOutranksAGenericVibeShelf() {
        let generic = makeMix("m0", title: "Под настроение")
        let calm = makeMix("m1", title: "Спокойный вечер")

        XCTAssertEqual(
            MixMoodLaunchPolicy.resolve(mood: .calm, in: [generic, calm]),
            .mix(calm)
        )
    }

    func testNoMoodFallsBackToThePersonalStation() {
        let personal = makeMix(MusicMix.common.id, title: "Составлено Селеной")

        XCTAssertEqual(
            MixMoodLaunchPolicy.resolve(mood: .any, in: [personal]),
            .mix(personal)
        )
    }

    func testEmptyCatalogFallsBackToMyMusic() {
        XCTAssertEqual(
            MixMoodLaunchPolicy.resolve(mood: .energetic, in: []),
            .myMusic
        )
    }
}

@MainActor
final class HomeStageMetricsTests: XCTestCase {
    /// 375 is an SE / mini, 430 a Pro Max.
    private let widths: [CGFloat] = [375, 393, 430]

    func testHeadlineStaysInTheSpecifiedBand() {
        for width in widths {
            let size = HomeStageMetrics.headlineSize(for: width)
            XCTAssertGreaterThanOrEqual(size, 32)
            XCTAssertLessThanOrEqual(size, 38)
        }
    }

    func testArtworkAndControlsStayInTheSpecifiedBands() {
        for width in widths {
            let artwork = HomeStageMetrics.artworkSize(for: width)
            XCTAssertGreaterThanOrEqual(artwork, 125)
            XCTAssertLessThanOrEqual(artwork, 145)

            let control = HomeStageMetrics.controlHeight(for: width)
            XCTAssertGreaterThanOrEqual(control, 48)
            XCTAssertLessThanOrEqual(control, 52)
        }
    }

    /// The point of the whole refactor: the stage is a hero block on a
    /// page, so the next shelf has to be visible without a full-screen
    /// scroll. An SE leaves roughly 518 pt between the status bar and the
    /// floating dock.
    func testNextShelfIsVisibleOnTheShortestScreen() {
        let height = HomeStageMetrics.stageHeight(for: 375)

        XCTAssertLessThan(height, 440)
        XCTAssertGreaterThan(
            518 - height,
            80,
            "at least a shelf row should show under the stage"
        )
    }

    /// Home reads as a feed with a hero block at the top, not as a second
    /// full-screen player — the hero alone (before the context rail) has
    /// to stay well clear of "almost the whole screen."
    func testHeroWithoutRailStaysCompact() {
        for width in widths {
            let withRail = HomeStageMetrics.stageHeight(for: width)
            let rail = HomeStageMetrics.railHeight(for: width)
            let heroOnly = withRail - rail

            XCTAssertGreaterThanOrEqual(heroOnly, 280)
            XCTAssertLessThanOrEqual(heroOnly, 360)
        }
    }

    /// Even the worst case — a two-line feature credit — must not turn the
    /// stage into a full screen of its own.
    func testTwoLineHeadlineStillFitsOneScreen() {
        for width in widths {
            let height = HomeStageMetrics.stageHeight(
                for: width,
                headlineLines: 2
            )
            XCTAssertLessThan(height, 518)
        }
    }

    /// The rail is exactly as tall as its tiles — a compact contextual
    /// shortcut, not a second hero sized to compete with the artwork.
    func testRailMatchesTheCompactContextTileBand() {
        for width in widths {
            let rail = HomeStageMetrics.railHeight(for: width)
            XCTAssertEqual(rail, BubbleMetrics.contextTileHeight(for: width))
            XCTAssertGreaterThanOrEqual(rail, 72)
            XCTAssertLessThanOrEqual(rail, 88)
        }
    }

    /// The atmosphere has to bleed behind the status bar / nav bar rather
    /// than stop at the safe-area boundary — that boundary is exactly what
    /// used to read as a separate black block above the hero. Passing the
    /// real inset must grow the band by that same amount, and omitting it
    /// must fall back to the un-extended height untouched call sites relied
    /// on before this existed.
    func testAtmosphereHeightExtendsByTheTopSafeAreaInset() {
        for width in widths {
            let base = HomeStageMetrics.atmosphereHeight(for: width)
            XCTAssertEqual(
                HomeStageMetrics.atmosphereHeight(
                    for: width,
                    topSafeAreaInset: 0
                ),
                base
            )
            XCTAssertEqual(
                HomeStageMetrics.atmosphereHeight(
                    for: width,
                    topSafeAreaInset: 59
                ),
                base + 59
            )
        }
    }
}

@MainActor
final class BubbleSystemTests: XCTestCase {
    private let widths: [CGFloat] = [375, 393, 430]

    /// Priority now carries a subtle width difference between context
    /// tiles, not an enormous size jump — the tile is a shortcut, and a
    /// shortcut sized like a second hero competed with the artwork above
    /// it. Height stays fixed across the rail regardless of priority.
    func testContextTileWidthFollowsPriorityNotPosition() {
        for width in widths {
            let primary = BubbleMetrics.contextTileWidth(
                for: width,
                priority: .primary
            )
            let secondary = BubbleMetrics.contextTileWidth(
                for: width,
                priority: .secondary
            )
            let tertiary = BubbleMetrics.contextTileWidth(
                for: width,
                priority: .tertiary
            )

            XCTAssertGreaterThan(primary, secondary)
            XCTAssertGreaterThan(secondary, tertiary)

            XCTAssertGreaterThanOrEqual(tertiary, 96)
            XCTAssertLessThanOrEqual(primary, 155)

            let height = BubbleMetrics.contextTileHeight(for: width)
            XCTAssertGreaterThanOrEqual(height, 72)
            XCTAssertLessThanOrEqual(height, 88)
        }
    }

    func testActionBubblesNeverDropBelowTheTapTarget() {
        for width in widths {
            XCTAssertGreaterThanOrEqual(
                BubbleMetrics.action(for: width),
                BubbleMetrics.minimumTapTarget
            )
            XCTAssertLessThanOrEqual(BubbleMetrics.action(for: width), 50)
            XCTAssertLessThanOrEqual(
                BubbleMetrics.action(for: width, prominent: true),
                52
            )
        }
    }

    func testRailLeavesTrailingRoomForTheLastBubble() {
        for width in widths {
            XCTAssertGreaterThanOrEqual(
                BubbleMetrics.railTrailingInset(for: width),
                24
            )
        }
    }

    /// Every role has to resolve to something legible even with no
    /// artwork, or the rail loses its colour legend on a cold start.
    func testEveryRoleHasAUsableFallback() {
        for role in BubbleRole.allCases {
            let components = BubblePalette.fallback(role)
            XCTAssertGreaterThan(components.luminance, 0.05)
            XCTAssertLessThan(components.luminance, 0.75)
        }
    }

    /// A washed-out or near-grey cover must not replace the role colour,
    /// otherwise a pale album turns the bubble into a white hole.
    func testDesaturatedArtworkKeepsTheRoleColour() {
        let grey = BubbleColorComponents(red: 0.5, green: 0.5, blue: 0.52)

        XCTAssertEqual(
            BubblePalette.surface(.artist, tint: grey),
            BubblePalette.fallback(.artist)
        )
    }

    func testArtworkTintIsPulledIntoTheLegibleBand() {
        let glaring = BubbleColorComponents(red: 1, green: 0.95, blue: 0.1)
        let surface = BubblePalette.surface(.mix, tint: glaring)

        XCTAssertLessThanOrEqual(
            surface.luminance,
            BubblePalette.surfaceLuminanceCeiling + 0.001
        )
    }

    /// A mostly-black cover should still yield its accent rather than
    /// reporting "black" — that is the whole point of weighting by
    /// saturation.
    func testTintExtractionFavoursTheSaturatedPixels() {
        var pixels: [UInt8] = []
        for _ in 0..<60 {
            pixels.append(contentsOf: [4, 4, 4, 255])
        }
        for _ in 0..<4 {
            pixels.append(contentsOf: [220, 40, 30, 255])
        }

        let tint = BubbleArtworkTint.extract(rgba: pixels)
        XCTAssertNotNil(tint)
        XCTAssertGreaterThan(tint?.red ?? 0, tint?.blue ?? 1)
        XCTAssertGreaterThan(tint?.saturation ?? 0, 0.3)
    }

    func testTintExtractionRejectsMalformedBuffers() {
        XCTAssertNil(BubbleArtworkTint.extract(rgba: []))
        XCTAssertNil(BubbleArtworkTint.extract(rgba: [255, 0, 0]))
    }

    func testFullyTransparentArtworkYieldsNoTint() {
        let clear = [UInt8](repeating: 0, count: 64)

        XCTAssertNil(BubbleArtworkTint.extract(rgba: clear))
    }
}

@MainActor
final class BottomAccessoryMetricsTests: XCTestCase {
    /// Before the dock has measured itself the inset still has to clear
    /// it, or the first shelf paints underneath on the very first frame.
    func testEstimateCoversTheDockBeforeItMeasuresItself() {
        let inset = BottomAccessoryMetrics.inset(
            measuredDockHeight: 0,
            hasMiniPlayer: false
        )

        XCTAssertGreaterThanOrEqual(
            inset,
            BottomAccessoryMetrics.estimatedDockHeight
        )
    }

    func testMiniPlayerAddsRoomToTheEstimate() {
        XCTAssertGreaterThan(
            BottomAccessoryMetrics.inset(
                measuredDockHeight: 0,
                hasMiniPlayer: true
            ),
            BottomAccessoryMetrics.inset(
                measuredDockHeight: 0,
                hasMiniPlayer: false
            )
        )
    }

    /// A real measurement wins over the estimate, and always keeps a gap
    /// between the last row and the chrome.
    func testMeasuredDockWinsAndKeepsClearance() {
        let inset = BottomAccessoryMetrics.inset(
            measuredDockHeight: 120,
            hasMiniPlayer: true
        )

        XCTAssertEqual(
            inset,
            120 + BottomAccessoryMetrics.contentClearance
        )
    }
}
