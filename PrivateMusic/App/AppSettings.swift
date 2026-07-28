import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        self == .dark ? "Тёмная" : "Светлая"
    }

    var colors: [Color] {
        self == .dark
            ? [Color.black, Color(white: 0.055)]
            : [Color.white, Color(white: 0.965)]
    }

    var accent: Color {
        self == .dark ? .white : .black
    }

    var secondaryAccent: Color {
        self == .dark ? Color(white: 0.32) : Color(white: 0.78)
    }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var buttonForeground: Color { self == .dark ? .black : .white }
    var surface: Color {
        self == .dark ? Color(white: 0.075) : Color(white: 0.955)
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Системная"
        case .dark: "Тёмная"
        case .light: "Светлая"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat
    case bass
    case vocal
    case electronic
    case rock
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Без обработки"
        case .bass: "Больше баса"
        case .vocal: "Вокал"
        case .electronic: "Электроника"
        case .rock: "Рок"
        case .custom: "Своя"
        }
    }

    var gains: [Double] {
        switch self {
        case .flat: [0, 0, 0, 0, 0]
        case .bass: [6, 4, 1, 0, -1]
        case .vocal: [-2, -1, 3, 4, 2]
        case .electronic: [5, 2, -1, 2, 5]
        case .rock: [4, 2, -1, 3, 4]
        case .custom: [0, 0, 0, 0, 0]
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published var liquidGlassEnabled: Bool {
        didSet {
            defaults.set(liquidGlassEnabled, forKey: Keys.liquidGlass)
        }
    }
    @Published var equalizerEnabled: Bool {
        didSet { defaults.set(equalizerEnabled, forKey: Keys.equalizer) }
    }
    @Published var equalizerPreset: EqualizerPreset {
        didSet { defaults.set(equalizerPreset.rawValue, forKey: Keys.preset) }
    }
    @Published var equalizerGains: [Double] {
        didSet { defaults.set(equalizerGains, forKey: Keys.gains) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settingsVersion = defaults.integer(forKey: Keys.version)
        if settingsVersion < 3 {
            theme = .dark
            appearance = .dark
            defaults.set(AppTheme.dark.rawValue, forKey: Keys.theme)
            defaults.set(AppearanceMode.dark.rawValue, forKey: Keys.appearance)
            defaults.set(3, forKey: Keys.version)
        } else {
            theme = AppTheme(
                rawValue: defaults.string(forKey: Keys.theme) ?? ""
            ) ?? .dark
            appearance = AppearanceMode(
                rawValue: defaults.string(forKey: Keys.appearance) ?? ""
            ) ?? .system
        }
        liquidGlassEnabled = defaults.object(
            forKey: Keys.liquidGlass
        ) as? Bool ?? true
        equalizerEnabled = defaults.object(
            forKey: Keys.equalizer
        ) as? Bool ?? false
        equalizerPreset = EqualizerPreset(
            rawValue: defaults.string(forKey: Keys.preset) ?? ""
        ) ?? .flat
        let savedGains = defaults.array(forKey: Keys.gains) as? [Double]
        if let savedGains, savedGains.count == 5 {
            equalizerGains = savedGains
        } else {
            equalizerGains = EqualizerPreset.flat.gains
        }
    }

    func selectPreset(_ preset: EqualizerPreset) {
        equalizerPreset = preset
        guard preset != .custom else { return }
        equalizerGains = preset.gains
    }

    func setGain(_ gain: Double, at index: Int) {
        guard equalizerGains.indices.contains(index) else { return }
        equalizerGains[index] = min(max(gain, -12), 12)
        equalizerPreset = .custom
    }

    func resetAppearance() {
        theme = .dark
        appearance = .dark
        liquidGlassEnabled = true
    }

    private enum Keys {
        static let version = "settings.schema.version"
        static let theme = "appearance.theme"
        static let appearance = "appearance.mode"
        static let liquidGlass = "appearance.liquidGlass"
        static let equalizer = "audio.equalizer.enabled"
        static let preset = "audio.equalizer.preset"
        static let gains = "audio.equalizer.gains"
    }
}
