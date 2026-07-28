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
        Color(red: 0.04, green: 0.50, blue: 1.0)
    }

    var secondaryAccent: Color {
        self == .dark ? Color(white: 0.32) : Color(white: 0.78)
    }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var buttonForeground: Color { .white }
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

enum AppTextScale: String, CaseIterable, Identifiable {
    case compact
    case system
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Компактный"
        case .system: "Системный"
        case .large: "Крупный"
        case .extraLarge: "Очень крупный"
        }
    }

    var subtitle: String {
        switch self {
        case .compact: "90%"
        case .system: "100%"
        case .large: "115%"
        case .extraLarge: "130%"
        }
    }

    var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .compact: .medium
        case .system: nil
        case .large: .xLarge
        case .extraLarge: .xxLarge
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
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: [6, 6, 5, 3, 1, 0, 0, 0, -1, -1]
        case .vocal: [-2, -2, -1, 0, 2, 4, 4, 3, 1, 0]
        case .electronic: [5, 4, 2, 0, -1, 0, 2, 3, 5, 5]
        case .rock: [4, 3, 2, 0, -1, 1, 3, 4, 4, 3]
        case .custom: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
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
    @Published var textScale: AppTextScale {
        didSet { defaults.set(textScale.rawValue, forKey: Keys.textScale) }
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
    @Published var equalizerPreamp: Double {
        didSet { defaults.set(equalizerPreamp, forKey: Keys.preamp) }
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
        textScale = AppTextScale(
            rawValue: defaults.string(forKey: Keys.textScale) ?? ""
        ) ?? .system
        equalizerEnabled = defaults.object(
            forKey: Keys.equalizer
        ) as? Bool ?? false
        equalizerPreset = EqualizerPreset(
            rawValue: defaults.string(forKey: Keys.preset) ?? ""
        ) ?? .flat
        let savedGains = defaults.array(forKey: Keys.gains) as? [Double]
        if let savedGains, savedGains.count == 10 {
            equalizerGains = savedGains
        } else {
            equalizerGains = EqualizerPreset.flat.gains
        }
        equalizerPreamp = defaults.object(forKey: Keys.preamp) as? Double ?? 0
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
        textScale = .system
    }

    private enum Keys {
        static let version = "settings.schema.version"
        static let theme = "appearance.theme"
        static let appearance = "appearance.mode"
        static let liquidGlass = "appearance.liquidGlass"
        static let textScale = "appearance.textScale"
        static let equalizer = "audio.equalizer.enabled"
        static let preset = "audio.equalizer.preset"
        static let gains = "audio.equalizer.gains"
        static let preamp = "audio.equalizer.preamp"
    }
}

extension View {
    @ViewBuilder
    func appTextScale(_ scale: AppTextScale) -> some View {
        if let dynamicTypeSize = scale.dynamicTypeSize {
            self.dynamicTypeSize(dynamicTypeSize)
        } else {
            self
        }
    }
}
