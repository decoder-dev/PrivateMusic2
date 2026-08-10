import Foundation

/// Case- and diacritic-insensitive text matching backed by PrivateMusicCore.c.
///
/// The native fold only claims ASCII and Cyrillic, which is every query this
/// app realistically sees. Anything else — Latin accents, Greek, CJK — reports
/// back as unsupported and the caller falls through to Foundation, which stays
/// authoritative for those scripts.
enum NativeTextSearch {
    /// Fold `text` and hand the folded UTF-8 to `body`, which receives nil when
    /// the text leaves the native fast path. The buffer is scratch memory and
    /// must not escape.
    static func withFolded<R>(
        _ text: String,
        _ body: (UnsafeBufferPointer<UInt8>?) -> R
    ) -> R {
        var text = text
        return text.withUTF8 { input -> R in
            guard let base = input.baseAddress, !input.isEmpty else {
                return body(UnsafeBufferPointer<UInt8>(start: nil, count: 0))
            }
            // Folding never grows the text, so the input length always fits.
            return withUnsafeTemporaryAllocation(
                of: UInt8.self,
                capacity: input.count
            ) { scratch -> R in
                guard let output = scratch.baseAddress else {
                    return body(nil)
                }
                let written = pm_text_fold_utf8(
                    base,
                    Int32(input.count),
                    output,
                    Int32(input.count)
                )
                guard written >= 0 else { return body(nil) }
                return body(
                    UnsafeBufferPointer(start: output, count: Int(written))
                )
            }
        }
    }

    /// Foundation's folding, used as the reference and as the fallback.
    static func foundationFolded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .lowercased()
    }
}

/// A search needle folded once and matched against many candidates.
///
/// Building this per query instead of per row is the point: the old call sites
/// re-folded the needle for every candidate they tested.
struct FoldedSearchQuery {
    /// Folded needle for the Foundation fallback path.
    let foundationFolded: String
    private let nativeFolded: [UInt8]?

    init(_ query: String) {
        foundationFolded = NativeTextSearch.foundationFolded(query)
        nativeFolded = NativeTextSearch.withFolded(query) {
            folded -> [UInt8]? in
            guard let folded, let base = folded.baseAddress else { return nil }
            return Array(UnsafeBufferPointer(start: base, count: folded.count))
        }
    }

    var isEmpty: Bool { foundationFolded.isEmpty }

    /// Whether `candidate` contains the needle. An empty needle never matches,
    /// which is what `String.contains("")` reports.
    func matches(_ candidate: String) -> Bool {
        guard !isEmpty else { return false }
        guard let nativeFolded else {
            return NativeTextSearch.foundationFolded(candidate)
                .contains(foundationFolded)
        }
        return NativeTextSearch.withFolded(candidate) { folded -> Bool in
            guard let folded else {
                return NativeTextSearch.foundationFolded(candidate)
                    .contains(foundationFolded)
            }
            return nativeFolded.withUnsafeBufferPointer { needle in
                pm_text_find(
                    folded.baseAddress,
                    Int32(folded.count),
                    needle.baseAddress,
                    Int32(needle.count)
                ) >= 0
            }
        }
    }
}
