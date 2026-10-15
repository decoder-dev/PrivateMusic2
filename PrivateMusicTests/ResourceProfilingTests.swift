import UIKit
import XCTest
@testable import PrivateMusic

/// Repeatable CPU/time/memory workloads, not an estimate of iPhone battery use.
/// Timings are recorded without hard limits because shared CI hosts vary.
@MainActor
final class ResourceProfilingTests: XCTestCase {
    private var consumed = 0

    func testProgressClockWorkload() {
        let progress = PlaybackProgressModel()
        profile {
            for tick in 0..<10_000 {
                progress.update(Double(tick) / 2)
                self.consumed += progress.elapsedTime.formattedDuration.count
            }
        }
        XCTAssertGreaterThan(consumed, 0)
    }

    func testLibrarySearchWorkload() {
        let tracks = (0..<2_000).map { index in
            Track(trackID: index + 1, ownerID: 1, title: "Track \(index)",
                  artist: "Artist \(index % 20)", duration: 180,
                  streamURL: nil, artworkURL: nil)
        }
        profile {
            for query in ["track", "artist 1", "1999", "absent"] {
                for _ in 0..<10 {
                    self.consumed += tracks.filter {
                        $0.title.localizedCaseInsensitiveContains(query)
                            || $0.artist.localizedCaseInsensitiveContains(query)
                    }.count
                }
            }
        }
        XCTAssertGreaterThan(consumed, 0)
    }

    func testWarmArtworkCacheWorkload() {
        let cache = ArtworkImageCache()
        let url = URL(string: "https://profile.invalid/cover.png")!
        let image = artwork()
        cache.insert(image, for: url, maxPixelSize: 512)
        profile {
            for _ in 0..<10_000 {
                if cache.image(for: url, maxPixelSize: 512) != nil { self.consumed += 1 }
            }
        }
        XCTAssertGreaterThan(consumed, 0)
    }

    func testArtworkTintWorkload() {
        let image = artwork()
        profile {
            for _ in 0..<500 {
                if BubbleArtworkTint.extract(from: image) != nil { self.consumed += 1 }
            }
        }
        XCTAssertGreaterThan(consumed, 0)
    }

    func testReferenceArtworkTintWorkload() {
        let image = artwork()
        profile {
            for _ in 0..<500 {
                if BubbleArtworkTint.extract(from: image, interpolationQuality: .default) != nil {
                    self.consumed += 1
                }
            }
        }
        XCTAssertGreaterThan(consumed, 0)
    }

    private func profile(_ operation: @escaping () -> Void) {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
                options: options, block: operation)
    }

    private func artwork() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
    }
}
