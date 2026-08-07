import XCTest
@testable import PrivateMusic

final class MixFeedbackPolicyTests: XCTestCase {
    func testBansTrackAndArtist() {
        let track = makeTrack(id: 1, artist: "Alpha")
        let other = makeTrack(id: 2, artist: "Beta")
        let sameArtist = makeTrack(id: 3, artist: "Alpha")
        XCTAssertTrue(
            MixFeedbackPolicy.isBanned(
                track,
                trackIDs: [track.id],
                artists: []
            )
        )
        XCTAssertTrue(
            MixFeedbackPolicy.isBanned(
                sameArtist,
                trackIDs: [],
                artists: ["alpha"]
            )
        )
        XCTAssertFalse(
            MixFeedbackPolicy.isBanned(
                other,
                trackIDs: [track.id],
                artists: ["alpha"]
            )
        )
        let filtered = MixFeedbackPolicy.filtering(
            [track, other, sameArtist],
            trackIDs: [track.id],
            artists: ["alpha"]
        )
        XCTAssertEqual(filtered.map(\.id), [other.id])
    }

    private func makeTrack(id: Int, artist: String) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "Song \(id)",
            artist: artist,
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
    }
}

final class MixSeedRadioTests: XCTestCase {
    func testBlendPrefersRecommendationsAndDedupes() {
        let seeds = (1...6).map {
            Track(
                trackID: $0,
                ownerID: 1,
                title: "Seed \($0)",
                artist: "A",
                duration: 100,
                streamURL: nil,
                artworkURL: nil
            )
        }
        let recs = (1...10).map {
            Track(
                trackID: 100 + $0,
                ownerID: 1,
                title: "Rec \($0)",
                artist: "B",
                duration: 100,
                streamURL: nil,
                artworkURL: nil
            )
        }
        // Duplicate a seed id inside recommendations.
        let withDup = [
            Track(
                trackID: 1,
                ownerID: 1,
                title: "Seed 1 again",
                artist: "A",
                duration: 100,
                streamURL: nil,
                artworkURL: nil
            )
        ] + recs
        let blended = MixSeedRadio.blend(
            seeds: seeds,
            recommendations: withDup,
            limit: 12
        )
        XCTAssertEqual(Set(blended.map(\.id)).count, blended.count)
        XCTAssertLessThanOrEqual(blended.count, 12)
        XCTAssertTrue(blended.contains(where: { $0.trackID >= 100 }))
    }

    func testVibeShelfDetection() {
        XCTAssertTrue(MixSeedRadio.looksLikeVibeShelf("Вайбы на вечер"))
        XCTAssertTrue(MixSeedRadio.looksLikeVibeShelf("Спокойное настроение"))
        XCTAssertFalse(MixSeedRadio.looksLikeVibeShelf("Новые релизы"))
    }
}

final class StreamQualityPolicyTests: XCTestCase {
    func testPreferredPeakBitRate() {
        XCTAssertEqual(
            StreamQualityPolicy.preferredPeakBitRate(preferHighQuality: true),
            0
        )
        XCTAssertEqual(
            StreamQualityPolicy.preferredPeakBitRate(preferHighQuality: false),
            160_000
        )
    }

    func testPrefersHQDuplicate() {
        let standard = Track(
            trackID: 1,
            ownerID: 1,
            title: "A",
            artist: "B",
            duration: 100,
            streamURL: nil,
            artworkURL: nil,
            isHQ: false
        )
        let hq = Track(
            trackID: 1,
            ownerID: 1,
            title: "A",
            artist: "B",
            duration: 100,
            streamURL: nil,
            artworkURL: nil,
            isHQ: true
        )
        XCTAssertTrue(
            StreamQualityPolicy.preferredDuplicate(
                existing: standard,
                candidate: hq
            ).isHQ
        )
        XCTAssertTrue(
            StreamQualityPolicy.preferredDuplicate(
                existing: hq,
                candidate: standard
            ).isHQ
        )
    }
}

final class TrackHQDecodingTests: XCTestCase {
    func testDecodesIsHQFlag() throws {
        let json = """
        {
          "id": 10,
          "owner_id": 20,
          "title": "HQ Song",
          "artist": "Artist",
          "duration": 120,
          "url": "https://example.com/a.mp3",
          "is_hq": 1
        }
        """.data(using: .utf8)!
        let track = try JSONDecoder().decode(Track.self, from: json)
        XCTAssertTrue(track.isHQ)
        XCTAssertEqual(track.id, "20_10")
    }

    func testMissingIsHQDefaultsFalse() throws {
        let json = """
        {
          "id": 11,
          "owner_id": 20,
          "title": "Song",
          "artist": "Artist",
          "duration": 120
        }
        """.data(using: .utf8)!
        let track = try JSONDecoder().decode(Track.self, from: json)
        XCTAssertFalse(track.isHQ)
    }
}

final class MixRationaleEnrichmentTests: XCTestCase {
    func testIncludesNoveltyLineWhenManyNewArtists() {
        let history = [
            ListeningHistoryEntry(
                track: Track(
                    trackID: 1,
                    ownerID: 1,
                    title: "Old",
                    artist: "Alpha",
                    duration: 100,
                    streamURL: nil,
                    artworkURL: nil
                ),
                playedAt: Date()
            )
        ]
        let mix = (2...8).map {
            Track(
                trackID: $0,
                ownerID: 1,
                title: "N\($0)",
                artist: "Artist\($0)",
                duration: 100,
                streamURL: nil,
                artworkURL: nil
            )
        }
        let rationale = MixRationaleBuilder.build(
            mixTracks: mix,
            history: history,
            recommendations: [],
            limit: 5
        )
        XCTAssertTrue(
            rationale.lines.contains {
                $0.contains("новые") || $0.contains("артистов")
            }
        )
    }
}
