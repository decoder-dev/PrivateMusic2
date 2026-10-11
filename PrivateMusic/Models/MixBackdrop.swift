import Foundation

/// The four corner colours of a mix's backdrop.
///
/// VK ships no still cover for a mix tile — only `background_animation_url`,
/// a Lottie animation of coloured blobs drifting in the corners (the official
/// app plays it behind the title). The animation cannot be drawn without a
/// Lottie renderer, but its palette can: the corner colours are read from the
/// file and painted as a static gradient, which is what the official app
/// shows for the same mix in notifications and shares.
struct MixBackdropPalette: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }

    let topLeading: RGB
    let topTrailing: RGB
    let bottomLeading: RGB
    let bottomTrailing: RGB
}

extension MixBackdropPalette {
    /// A stable four-colour palette derived from the mix id, so a mix with
    /// no cover and no usable tracks still gets its own recognisable
    /// artwork instead of the same flat colour as every other mix.
    static func generated(for id: String) -> MixBackdropPalette {
        let seed = id.unicodeScalars.reduce(UInt32(5381)) {
            ($0 &* 33) &+ $1.value
        }
        let base = Double(seed % 360) / 360
        func colour(_ shift: Double, _ brightness: Double) -> RGB {
            let hue = (base + shift).truncatingRemainder(dividingBy: 1)
            let (red, green, blue) = hsb(hue, 0.72, brightness)
            return RGB(red: red, green: green, blue: blue)
        }
        return MixBackdropPalette(
            topLeading: colour(0.00, 0.98),
            topTrailing: colour(0.14, 0.78),
            bottomLeading: colour(0.50, 0.92),
            bottomTrailing: colour(0.64, 0.62)
        )
    }

    private static func hsb(
        _ hue: Double,
        _ saturation: Double,
        _ brightness: Double
    ) -> (Double, Double, Double) {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return (brightness, rising, low)
        case 1: return (falling, brightness, low)
        case 2: return (low, brightness, rising)
        case 3: return (low, falling, brightness)
        case 4: return (rising, low, brightness)
        default: return (brightness, low, falling)
        }
    }
}

enum MixBackdropParser {
    /// Reads the corner colours out of a Lottie file; nil when the data is
    /// not a Lottie animation or carries no usable colour.
    static func palette(fromLottie data: Data) -> MixBackdropPalette? {
        guard let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let layers = root["layers"] as? [[String: Any]] else {
            return nil
        }
        var named: [String: MixBackdropPalette.RGB] = [:]
        var ordered: [MixBackdropPalette.RGB] = []
        for layer in layers {
            guard let color = firstColor(in: layer["shapes"]) else { continue }
            let name = (layer["nm"] as? String)?.lowercased() ?? ""
            if name.contains("bg") || name.contains("background") {
                continue
            }
            ordered.append(color)
            for corner in ["top_left", "top_right", "bottom_left", "bottom_right"]
            where name.contains(corner) {
                named[corner] = color
            }
        }
        guard !ordered.isEmpty else { return nil }
        func pick(_ corner: String, _ index: Int) -> MixBackdropPalette.RGB {
            named[corner] ?? ordered[index % ordered.count]
        }
        return MixBackdropPalette(
            topLeading: pick("top_left", 0),
            topTrailing: pick("top_right", 1),
            bottomLeading: pick("bottom_left", 2),
            bottomTrailing: pick("bottom_right", 3)
        )
    }

    /// First solid or gradient colour found inside a Lottie shape tree.
    private static func firstColor(in node: Any?) -> MixBackdropPalette.RGB? {
        if let list = node as? [Any] {
            for item in list {
                if let color = firstColor(in: item) { return color }
            }
            return nil
        }
        guard let object = node as? [String: Any] else { return nil }
        let type = object["ty"] as? String
        if type == "gf",
           let gradient = object["g"] as? [String: Any],
           let stops = (gradient["k"] as? [String: Any])?["k"] as? [Double],
           stops.count >= 4 {
            return normalized(stops[1], stops[2], stops[3])
        }
        if type == "fl",
           let colour = (object["c"] as? [String: Any])?["k"] as? [Double],
           colour.count >= 3 {
            return normalized(colour[0], colour[1], colour[2])
        }
        for value in object.values {
            if value is [Any] || value is [String: Any],
               let color = firstColor(in: value) {
                return color
            }
        }
        return nil
    }

    private static func normalized(
        _ red: Double,
        _ green: Double,
        _ blue: Double
    ) -> MixBackdropPalette.RGB {
        let scale = max(red, green, blue) > 1 ? 255.0 : 1.0
        func clamp(_ value: Double) -> Double {
            min(max(value / scale, 0), 1)
        }
        return MixBackdropPalette.RGB(
            red: clamp(red),
            green: clamp(green),
            blue: clamp(blue)
        )
    }
}

/// Downloads and memoises backdrop palettes, one request per URL.
actor MixBackdropStore {
    static let shared = MixBackdropStore()

    private var cache: [URL: MixBackdropPalette?] = [:]
    /// One download per URL even when several cards ask at once.
    private var inFlight: [URL: Task<MixBackdropPalette?, Never>] = [:]
    private static let maxBytes = 600_000

    func palette(for url: URL) async -> MixBackdropPalette? {
        if let cached = cache[url] { return cached }
        // Only Lottie json is understood; a video or image URL is skipped
        // without a download.
        guard url.pathExtension.lowercased() == "json" else {
            cache[url] = .some(nil)
            return nil
        }
        if let running = inFlight[url] { return await running.value }
        let task = Task<MixBackdropPalette?, Never> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(
                for: request
            ) else {
                return nil
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= Self.maxBytes else {
                return nil
            }
            return MixBackdropParser.palette(fromLottie: data)
        }
        inFlight[url] = task
        let palette = await task.value
        inFlight[url] = nil
        // A palette is kept for the run. A failure is not: a dropped
        // connection must not leave the card on the generated colours
        // until the next launch.
        if let palette { cache[url] = .some(palette) }
        return palette
    }
}
