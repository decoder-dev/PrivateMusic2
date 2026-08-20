import XCTest
@testable import PrivateMusic

/// `MixFeedbackPolicy.normalized` is the one answer to "is this the same
/// artist". Bans, artist affinity, the mix rationale, album matching, the
/// artist screen's track filter and the queue ranker all key off it, so a
/// change here moves all of them at once — which is the point, and the
/// reason it is worth pinning down.
final class ArtistIdentityKeyTests: XCTestCase {
    private func key(_ value: String) -> String {
        MixFeedbackPolicy.normalized(value)
    }

    func testCaseAndSurroundingSpaceDoNotMakeADifferentArtist() {
        XCTAssertEqual(key("  Nine Inch Nails  "), key("nine inch nails"))
        XCTAssertEqual(key("ЛЕНИНГРАД"), key("Ленинград"))
    }

    /// VK does not spell Russian names consistently: the same artist can
    /// arrive precomposed ("й", U+0439) or decomposed ("и" + U+0306). If
    /// those produced different keys, banning an artist would only ban one
    /// of their spellings.
    func testTheTwoWaysToSpellShortIAgree() {
        let decomposed = "Валери\u{0306}"
        let precomposed = "Валерий"

        XCTAssertNotEqual(decomposed, precomposed, "the inputs must differ")
        XCTAssertEqual(key(decomposed), key(precomposed))
    }

    func testYoAndYeAreTheSameArtist() {
        XCTAssertEqual(key("Пётр"), key("Петр"))
    }

    /// This key is the forgiving one on purpose — it exists to match an
    /// artist however VK happened to spell them. Text that must keep `й`
    /// distinct goes through `MixQueueFilter`'s mood folding instead, and
    /// the two are documented against each other.
    func testShortIFoldsOntoIAsTheForgivingKey() {
        XCTAssertEqual(key("Май"), key("Маи"))
    }

    func testAnEmptyOrBlankNameHasNoKey() {
        XCTAssertTrue(key("").isEmpty)
        XCTAssertTrue(key("   ").isEmpty)
    }

    /// The queue ranker folds artist names through the native fast path and
    /// falls back to `MixFeedbackPolicy.normalized` when that path declines
    /// a letter it does not cover. The two have to agree on everything the
    /// fast path *does* accept, or one artist would be two people to the
    /// ranker and one to the ban list.
    func testTheNativeFastPathAgreesWithTheFoundationKey() {
        for name in [
            "Валерий",
            "Ленинград",
            "Пётр",
            "  Мельница  ",
            "Nine Inch Nails",
            "ДДТ",
            "Ёлка"
        ] {
            let native = nativeIdentity(name)
            guard !native.isEmpty else {
                // The fast path declined this one; the fallback answers
                // instead, so there is nothing to compare.
                continue
            }
            XCTAssertEqual(
                native,
                key(name),
                "native and Foundation folding disagree on \(name)"
            )
        }
    }

    private func nativeIdentity(_ text: String) -> String {
        var text = text
        return text.withUTF8 { input -> String in
            guard let base = input.baseAddress else { return "" }
            return withUnsafeTemporaryAllocation(
                of: UInt8.self,
                capacity: input.count
            ) { scratch -> String in
                guard let output = scratch.baseAddress else { return "" }
                let written = pm_text_normalize_identity(
                    base,
                    Int32(input.count),
                    output,
                    Int32(input.count)
                )
                guard written >= 0 else { return "" }
                return String(
                    decoding: UnsafeBufferPointer(
                        start: output,
                        count: Int(written)
                    ),
                    as: UTF8.self
                )
            }
        }
    }
}
