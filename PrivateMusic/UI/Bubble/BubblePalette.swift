import SwiftUI
import UIKit

/// Semantic colour roles for Bubble UI. Feature views were reaching for
/// literal `Color(red:green:blue:)` values, which is how a palette drifts
/// out of sync with itself — the same "artist orange" existed twice with
/// different numbers.
enum BubbleRole: String, Hashable, Sendable, CaseIterable {
    case station
    case artist
    case mood
    case mix
    case recommendation
    case neutral
    case accent
    case success
    case destructive
}

/// Colour components kept as numbers rather than `Color` so the resolver
/// stays `Sendable` and, more usefully, testable without a renderer.
struct BubbleColorComponents: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Rough perceptual luminance. Used to keep white label text legible
    /// on top of whatever the artwork happens to be.
    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    var saturation: Double {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        guard high > 0 else { return 0 }
        return (high - low) / high
    }

    /// Pulls a colour into the band where white text on it still reads and
    /// the surface does not vibrate. Artwork gives plenty of colours that
    /// are too pale, too dark or too saturated to sit under a label.
    func constrainedForSurface() -> BubbleColorComponents {
        var result = self
        let target = BubblePalette.surfaceLuminanceCeiling
        if result.luminance > target, result.luminance > 0 {
            let scale = target / result.luminance
            result = result.scaled(by: scale)
        }
        let floor = BubblePalette.surfaceLuminanceFloor
        if result.luminance < floor {
            let lift = floor - result.luminance
            result = BubbleColorComponents(
                red: min(1, result.red + lift),
                green: min(1, result.green + lift),
                blue: min(1, result.blue + lift)
            )
        }
        return result
    }

    func scaled(by factor: Double) -> BubbleColorComponents {
        BubbleColorComponents(
            red: min(1, max(0, red * factor)),
            green: min(1, max(0, green * factor)),
            blue: min(1, max(0, blue * factor))
        )
    }
}

enum BubblePalette {
    /// White-on-colour stops reading above this, and a fill below it looks
    /// like a hole rather than an object.
    static let surfaceLuminanceCeiling: Double = 0.62
    static let surfaceLuminanceFloor: Double = 0.16

    /// The fallback every role resolves to when no artwork tint applies.
    /// Values come from `BubbleGamut` so the legend and the rest of the app
    /// share one palette.
    static func fallback(_ role: BubbleRole) -> BubbleColorComponents {
        BubbleGamut.components(for: role)
    }

    static func color(_ role: BubbleRole) -> Color {
        fallback(role).color
    }

    /// Role first, artwork second: a tint only replaces the fallback when
    /// it survives the surface constraints. Otherwise the rail would lose
    /// its legend the moment somebody played an album with grey artwork.
    static func surface(
        _ role: BubbleRole,
        tint: BubbleColorComponents?
    ) -> BubbleColorComponents {
        guard let tint, tint.saturation >= 0.22 else {
            return fallback(role)
        }
        return tint.constrainedForSurface()
    }
}

/// Dominant colour of a piece of artwork.
///
/// Extraction is split in two: the arithmetic is a pure function over
/// pixel bytes, and the decoding is the part that touches UIKit. That way
/// the interesting half is a unit test rather than a screenshot.
enum BubbleArtworkTint {
    /// Averages the pixels that actually carry colour, weighted by
    /// saturation, so a mostly-black cover still yields its accent rather
    /// than reporting "black".
    static func extract(rgba: [UInt8]) -> BubbleColorComponents? {
        guard rgba.count >= 4, rgba.count % 4 == 0 else { return nil }
        var weightedRed = 0.0
        var weightedGreen = 0.0
        var weightedBlue = 0.0
        var totalWeight = 0.0

        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Double(rgba[pixel + 3]) / 255
            guard alpha > 0.4 else { continue }
            let red = Double(rgba[pixel]) / 255
            let green = Double(rgba[pixel + 1]) / 255
            let blue = Double(rgba[pixel + 2]) / 255
            let components = BubbleColorComponents(
                red: red,
                green: green,
                blue: blue
            )
            // Saturation-weighted, with a small floor so a fully neutral
            // cover still produces its grey instead of nothing at all.
            let weight = alpha * (0.08 + components.saturation)
            weightedRed += red * weight
            weightedGreen += green * weight
            weightedBlue += blue * weight
            totalWeight += weight
        }

        guard totalWeight > 0 else { return nil }
        return BubbleColorComponents(
            red: weightedRed / totalWeight,
            green: weightedGreen / totalWeight,
            blue: weightedBlue / totalWeight
        )
    }

    /// Samples an 8×8 thumbnail — 64 pixels is plenty for a dominant
    /// colour and cheap enough to stay off the critical path.
    static let sampleEdge = 8

    static func extract(from image: UIImage) -> BubbleColorComponents? {
        guard let cgImage = image.cgImage else { return nil }
        let edge = sampleEdge
        var buffer = [UInt8](repeating: 0, count: edge * edge * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &buffer,
            width: edge,
            height: edge,
            bitsPerComponent: 8,
            bytesPerRow: edge * 4,
            space: space,
            bitmapInfo: info
        ) else {
            return nil
        }
        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: edge, height: edge)
        )
        return extract(rgba: buffer)
    }
}

/// Memoises artwork tints by URL. Extraction is cheap but not free, and
/// SwiftUI will happily ask for the same colour on every body evaluation.
@MainActor
@Observable
final class BubbleTintCache {
    static let shared = BubbleTintCache()

    /// Bumps whenever a URL's tint is resolved so views can refresh fills.
    private(set) var revision = 0

    private let storage = NSCache<NSString, TintBox>()
    /// URLs already sampled that produced nothing usable, so a grey cover
    /// is not re-decoded on every scroll.
    private var misses = Set<String>()

    private final class TintBox {
        let components: BubbleColorComponents
        init(_ components: BubbleColorComponents) {
            self.components = components
        }
    }

    private init() {
        storage.countLimit = 120
    }

    func cached(for url: URL?) -> BubbleColorComponents? {
        guard let key = url?.absoluteString as NSString? else { return nil }
        return storage.object(forKey: key)?.components
    }

    func hasResolved(_ url: URL?) -> Bool {
        guard let key = url?.absoluteString else { return false }
        return misses.contains(key)
            || storage.object(forKey: key as NSString) != nil
    }

    func store(_ components: BubbleColorComponents?, for url: URL?) {
        guard let key = url?.absoluteString else { return }
        let hadEntry = storage.object(forKey: key as NSString) != nil
            || misses.contains(key)
        guard let components else {
            if !misses.contains(key) {
                misses.insert(key)
                revision &+= 1
            }
            return
        }
        storage.setObject(TintBox(components), forKey: key as NSString)
        misses.remove(key)
        if !hadEntry {
            revision &+= 1
        }
    }

    /// Samples a loaded bitmap once and memoises the dominant colour. Every
    /// image load path funnels through here so Home's context rail can tint
    /// from artwork without re-decoding on every body pass.
    func recordArtwork(_ image: UIImage, for url: URL?) {
        guard let url else { return }
        guard !hasResolved(url) else { return }
        store(BubbleArtworkTint.extract(from: image), for: url)
    }
}
