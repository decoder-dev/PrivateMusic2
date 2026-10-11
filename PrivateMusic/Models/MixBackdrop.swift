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
    private static let maxBytes = 600_000

    func palette(for url: URL) async -> MixBackdropPalette? {
        if let cached = cache[url] { return cached }
        // Only Lottie json is understood; a video or image URL is skipped
        // without a download.
        guard url.pathExtension.lowercased() == "json" else {
            cache[url] = .some(nil)
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let palette: MixBackdropPalette?
        if let (data, response) = try? await URLSession.shared.data(
            for: request
        ),
           (response as? HTTPURLResponse)?.statusCode == 200,
           data.count <= Self.maxBytes {
            palette = MixBackdropParser.palette(fromLottie: data)
        } else {
            palette = nil
        }
        cache[url] = .some(palette)
        return palette
    }
}
