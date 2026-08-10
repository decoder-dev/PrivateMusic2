import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        L10n.text(self == .dark ? "Тёмная" : "Светлая")
    }

    var colors: [Color] {
        self == .dark
            ? [Color.black, Color(white: 0.055)]
            : [Color.white, Color(white: 0.965)]
    }

    var accent: Color {
        self == .dark
            ? Color(red: 0.04, green: 0.50, blue: 1.0)
            : .black
    }

    var secondaryAccent: Color {
        self == .dark ? Color(white: 0.32) : Color(white: 0.90)
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
        case .system: L10n.text("Системная")
        case .dark: L10n.text("Тёмная")
        case .light: L10n.text("Светлая")
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
        case .compact: L10n.text("Компактный")
        case .system: L10n.text("Системный")
        case .large: L10n.text("Крупный")
        case .extraLarge: L10n.text("Очень крупный")
        }
    }

    var subtitle: String {
        switch self {
        case .compact: "85%"
        case .system: "100%"
        case .large: "110%"
        case .extraLarge: "120%"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .compact: .medium
        case .system: .large
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
        case .flat: L10n.text("Без обработки")
        case .bass: L10n.text("Больше баса")
        case .vocal: L10n.text("Вокал")
        case .electronic: L10n.text("Электроника")
        case .rock: L10n.text("Рок")
        case .custom: L10n.text("Своя")
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
    @Published var preferHighQuality: Bool {
        didSet {
            defaults.set(preferHighQuality, forKey: Keys.preferHighQuality)
        }
    }
    @Published var mixMoodPreference: MixMoodPreference {
        didSet {
            defaults.set(
                mixMoodPreference.rawValue,
                forKey: Keys.mixMoodPreference
            )
        }
    }
    @Published var mixLanguagePreference: MixLanguagePreference {
        didSet {
            defaults.set(
                mixLanguagePreference.rawValue,
                forKey: Keys.mixLanguagePreference
            )
        }
    }
    @Published var mixFamiliarityPreference: MixFamiliarityPreference {
        didSet {
            defaults.set(
                mixFamiliarityPreference.rawValue,
                forKey: Keys.mixFamiliarityPreference
            )
        }
    }
    @Published var loudnessNormalization: Bool {
        didSet {
            defaults.set(
                loudnessNormalization,
                forKey: Keys.loudnessNormalization
            )
        }
    }
    @Published var dynamicRangeCompression: Bool {
        didSet {
            defaults.set(
                dynamicRangeCompression,
                forKey: Keys.dynamicRangeCompression
            )
        }
    }
    @Published var spatialAudioEnabled: Bool {
        didSet {
            defaults.set(
                spatialAudioEnabled,
                forKey: Keys.spatialAudioEnabled
            )
        }
    }
    @Published var spatialAudioIntensity: Double {
        didSet {
            let normalized = min(max(spatialAudioIntensity, 0), 1)
            if spatialAudioIntensity != normalized {
                spatialAudioIntensity = normalized
                return
            }
            defaults.set(normalized, forKey: Keys.spatialAudioIntensity)
        }
    }
    @Published var resumeOnBluetoothConnection: Bool {
        didSet {
            defaults.set(
                resumeOnBluetoothConnection,
                forKey: Keys.resumeOnBluetoothConnection
            )
        }
    }
    @Published var pauseAtMinimumVolume: Bool {
        didSet {
            defaults.set(
                pauseAtMinimumVolume,
                forKey: Keys.pauseAtMinimumVolume
            )
        }
    }
    @Published var appVolume: Double {
        didSet {
            let normalized = min(max(appVolume, 0), 1)
            if appVolume != normalized {
                appVolume = normalized
                return
            }
            defaults.set(normalized, forKey: Keys.appVolume)
        }
    }
    @Published var advanceOnPlaybackError: Bool {
        didSet {
            defaults.set(
                advanceOnPlaybackError,
                forKey: Keys.advanceOnPlaybackError
            )
        }
    }
    @Published var offlineStorageLimitGB: Int {
        didSet {
            let normalized = Self.normalizedOfflineStorageLimit(
                offlineStorageLimitGB
            )
            if offlineStorageLimitGB != normalized {
                offlineStorageLimitGB = normalized
            }
            defaults.set(normalized, forKey: Keys.offlineStorageLimitGB)
        }
    }
    @Published var automaticOfflineCacheEnabled: Bool {
        didSet {
            defaults.set(
                automaticOfflineCacheEnabled,
                forKey: Keys.automaticOfflineCacheEnabled
            )
        }
    }
    @Published var hapticsEnabled: Bool {
        didSet {
            defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled)
            Haptics.isEnabled = hapticsEnabled
        }
    }

    private let defaults: UserDefaults

    static let minimumOfflineStorageLimitGB = 5
    static let maximumOfflineStorageLimitGB = 100
    static let offlineStorageLimitStepGB = 5

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
        if settingsVersion < 4 {
            defaults.removeObject(forKey: LegacyKeys.liquidGlass)
            defaults.set(4, forKey: Keys.version)
        }
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
        preferHighQuality = defaults.object(
            forKey: Keys.preferHighQuality
        ) as? Bool ?? true
        mixMoodPreference = MixMoodPreference(
            rawValue: defaults.string(forKey: Keys.mixMoodPreference) ?? ""
        ) ?? .any
        mixLanguagePreference = MixLanguagePreference(
            rawValue: defaults.string(forKey: Keys.mixLanguagePreference) ?? ""
        ) ?? .any
        mixFamiliarityPreference = MixFamiliarityPreference(
            rawValue: defaults.string(
                forKey: Keys.mixFamiliarityPreference
            ) ?? ""
        ) ?? .any
        loudnessNormalization = defaults.object(
            forKey: Keys.loudnessNormalization
        ) as? Bool ?? false
        dynamicRangeCompression = defaults.object(
            forKey: Keys.dynamicRangeCompression
        ) as? Bool ?? false
        spatialAudioEnabled = defaults.object(
            forKey: Keys.spatialAudioEnabled
        ) as? Bool ?? false
        spatialAudioIntensity = min(
            max(
                defaults.object(
                    forKey: Keys.spatialAudioIntensity
                ) as? Double ?? SpatialAudioDSP.defaultIntensity,
                0
            ),
            1
        )
        resumeOnBluetoothConnection = defaults.object(
            forKey: Keys.resumeOnBluetoothConnection
        ) as? Bool ?? true
        pauseAtMinimumVolume = defaults.object(
            forKey: Keys.pauseAtMinimumVolume
        ) as? Bool ?? false
        appVolume = min(
            max(defaults.object(forKey: Keys.appVolume) as? Double ?? 1, 0),
            1
        )
        advanceOnPlaybackError = defaults.object(
            forKey: Keys.advanceOnPlaybackError
        ) as? Bool ?? true
        offlineStorageLimitGB = Self.normalizedOfflineStorageLimit(
            defaults.object(forKey: Keys.offlineStorageLimitGB) as? Int
                ?? Self.minimumOfflineStorageLimitGB
        )
        automaticOfflineCacheEnabled = defaults.object(
            forKey: Keys.automaticOfflineCacheEnabled
        ) as? Bool ?? false
        hapticsEnabled = defaults.object(
            forKey: Keys.hapticsEnabled
        ) as? Bool ?? true
        Haptics.isEnabled = hapticsEnabled
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
        textScale = .system
    }

    var offlineStorageLimitBytes: Int64 {
        Int64(offlineStorageLimitGB) * 1_000_000_000
    }

    private static func normalizedOfflineStorageLimit(_ value: Int) -> Int {
        let clamped = min(
            max(value, minimumOfflineStorageLimitGB),
            maximumOfflineStorageLimitGB
        )
        let offset = clamped - minimumOfflineStorageLimitGB
        let steps = Int(
            (Double(offset) / Double(offlineStorageLimitStepGB)).rounded()
        )
        return minimumOfflineStorageLimitGB
            + steps * offlineStorageLimitStepGB
    }

    private enum Keys {
        static let version = "settings.schema.version"
        static let theme = "appearance.theme"
        static let appearance = "appearance.mode"
        static let textScale = "appearance.textScale"
        static let equalizer = "audio.equalizer.enabled"
        static let preset = "audio.equalizer.preset"
        static let gains = "audio.equalizer.gains"
        static let preamp = "audio.equalizer.preamp"
        static let resumeOnBluetoothConnection =
            "audio.bluetooth.resumeOnConnection"
        static let pauseAtMinimumVolume =
            "audio.volume.pauseAtMinimum"
        static let appVolume = "audio.volume.appLevel"
        static let advanceOnPlaybackError =
            "audio.playback.advanceOnError"
        static let offlineStorageLimitGB =
            "offline.storage.limitGB"
        static let automaticOfflineCacheEnabled =
            "offline.cache.automatic.enabled"
        static let hapticsEnabled = "feedback.haptics.enabled"
        static let preferHighQuality = "audio.playback.preferHighQuality"
        static let mixMoodPreference = "mix.filters.mood"
        static let mixLanguagePreference = "mix.filters.language"
        static let mixFamiliarityPreference = "mix.filters.familiarity"
        static let loudnessNormalization =
            "audio.equalizer.loudnessNormalization"
        static let dynamicRangeCompression =
            "audio.equalizer.dynamicRangeCompression"
        static let spatialAudioEnabled = "audio.spatial.enabled"
        static let spatialAudioIntensity = "audio.spatial.intensity"
    }

    private enum LegacyKeys {
        static let liquidGlass = "appearance.liquidGlass"
    }
}

extension View {
    func appTextScale(_ scale: AppTextScale) -> some View {
        dynamicTypeSize(scale.dynamicTypeSize)
    }
}
