import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        L10n.text(self == .dark ? "appearance.dark" : "appearance.light")
    }

    var colors: [Color] {
        self == .dark
            ? [Color.black, Color(white: 0.055)]
            : [Color.white, Color(white: 0.965)]
    }

    var accent: Color {
        BubbleGamut.accentColor(for: self)
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

/// The interactive colour (tint, play buttons, hearts, selection). The first
/// case is the app's original blue and stays the default.
enum AppAccent: String, CaseIterable, Identifiable {
    case blue
    case indigo
    case violet
    case pink
    case red
    case orange
    case green
    case teal
    case banana

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: L10n.text("accent.blue")
        case .indigo: L10n.text("accent.indigo")
        case .violet: L10n.text("accent.violet")
        case .pink: L10n.text("accent.pink")
        case .red: L10n.text("accent.red")
        case .orange: L10n.text("accent.orange")
        case .green: L10n.text("accent.green")
        case .teal: L10n.text("accent.teal")
        case .banana: L10n.text("accent.banana")
        }
    }

    /// Dark surfaces take a lighter tone, light surfaces a deeper one. The light
    /// tones are deep enough (≥ 4.5:1 on the page, and under a white label)
    /// that accent-coloured text and glyphs stay readable, not only fills.
    func components(for theme: AppTheme) -> BubbleColorComponents {
        let dark = theme == .dark
        switch self {
        case .blue:
            return BubbleGamut.accent(for: theme)
        case .indigo:
            return dark
                ? BubbleColorComponents(red: 0.43, green: 0.45, blue: 0.98)
                : BubbleColorComponents(red: 0.31, green: 0.32, blue: 0.86)
        case .violet:
            return dark
                ? BubbleColorComponents(red: 0.70, green: 0.46, blue: 0.97)
                : BubbleColorComponents(red: 0.53, green: 0.30, blue: 0.80)
        case .pink:
            return dark
                ? BubbleColorComponents(red: 0.98, green: 0.40, blue: 0.64)
                : BubbleColorComponents(red: 0.75, green: 0.21, blue: 0.44)
        case .red:
            return dark
                ? BubbleColorComponents(red: 0.98, green: 0.38, blue: 0.38)
                : BubbleColorComponents(red: 0.78, green: 0.20, blue: 0.22)
        case .orange:
            return dark
                ? BubbleColorComponents(red: 1.00, green: 0.60, blue: 0.20)
                : BubbleColorComponents(red: 0.65, green: 0.34, blue: 0.06)
        case .green:
            return dark
                ? BubbleColorComponents(red: 0.30, green: 0.80, blue: 0.48)
                : BubbleColorComponents(red: 0.11, green: 0.48, blue: 0.27)
        case .teal:
            return dark
                ? BubbleColorComponents(red: 0.24, green: 0.80, blue: 0.80)
                : BubbleColorComponents(red: 0.06, green: 0.47, blue: 0.48)
        case .banana:
            // BananaGram's own pair: a soft yellow on graphite, a deep
            // gold on cream.
            return dark
                ? BubbleColorComponents(red: 0.957, green: 0.839, blue: 0.435)
                : BubbleColorComponents(red: 0.502, green: 0.337, blue: 0.0)
        }
    }

    /// The same accent on a palette's page: unchanged on the classic one,
    /// nudged lighter / darker elsewhere so it still reads at 4.5:1 on that
    /// palette's page and surface.
    func components(
        for theme: AppTheme,
        on palette: AppPalette
    ) -> BubbleColorComponents {
        let base = components(for: theme)
        guard palette != .classic else { return base }
        return base.ensuringContrast(
            against: palette.luminances(for: theme),
            towardWhite: theme == .dark
        )
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.text("appearance.system")
        case .dark: L10n.text("appearance.dark")
        case .light: L10n.text("appearance.light")
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
        case .compact: L10n.text("text_scale.compact")
        case .system: L10n.text("text_scale.system")
        case .large: L10n.text("text_scale.large")
        case .extraLarge: L10n.text("text_scale.extra_large")
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

    /// How this in-app preference maps onto Dynamic Type.
    ///
    /// `nil` means follow the system size (including accessibility sizes).
    /// Compact lowers the ceiling for standard sizes only. Accessibility
    /// sizes the reader already chose are never clamped — see
    /// `AppTextScalePolicy.resolvedRange(for:inherited:)`.
    var dynamicTypeRange: ClosedRange<DynamicTypeSize>? {
        AppTextScalePolicy.range(for: self)
    }
}

enum AppTextScalePolicy {
    static func range(
        for scale: AppTextScale
    ) -> ClosedRange<DynamicTypeSize>? {
        switch scale {
        case .compact:
            DynamicTypeSize.xSmall ... DynamicTypeSize.medium
        case .system:
            nil
        case .large:
            DynamicTypeSize.xLarge ... DynamicTypeSize.accessibility5
        case .extraLarge:
            DynamicTypeSize.xxLarge ... DynamicTypeSize.accessibility5
        }
    }

    /// Compact may shrink default sizes. It must not pull an accessibility
    /// size the reader already chose back down to `.medium`.
    static func resolvedRange(
        for scale: AppTextScale,
        inherited: DynamicTypeSize
    ) -> ClosedRange<DynamicTypeSize>? {
        if inherited.isAccessibilitySize {
            return nil
        }
        return range(for: scale)
    }
}

enum EqualizerPreset: String, CaseIterable, Identifiable {
    case flat
    case bass
    case bassReduction
    case trebleBoost
    case trebleReduction
    case vocal
    case vocalReduction
    case speech
    case acoustic
    case classical
    case piano
    case jazz
    case lounge
    case pop
    case rnb
    case hipHop
    case dance
    case electronic
    case rock
    case metal
    case loudness
    case smallSpeakers
    case headphones
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: L10n.text("flat")
        case .bass: L10n.text("bass_boost")
        case .bassReduction: L10n.text("eq.preset.bass_reduction")
        case .trebleBoost: L10n.text("eq.preset.treble_boost")
        case .trebleReduction: L10n.text("eq.preset.treble_reduction")
        case .vocal: L10n.text("vocal")
        case .vocalReduction: L10n.text("eq.preset.vocal_reduction")
        case .speech: L10n.text("eq.preset.speech")
        case .acoustic: L10n.text("eq.preset.acoustic")
        case .classical: L10n.text("eq.preset.classical")
        case .piano: L10n.text("eq.preset.piano")
        case .jazz: L10n.text("eq.preset.jazz")
        case .lounge: L10n.text("eq.preset.lounge")
        case .pop: L10n.text("eq.preset.pop")
        case .rnb: L10n.text("eq.preset.rnb")
        case .hipHop: L10n.text("eq.preset.hip_hop")
        case .dance: L10n.text("eq.preset.dance")
        case .electronic: L10n.text("electronic")
        case .rock: L10n.text("rock")
        case .metal: L10n.text("eq.preset.metal")
        case .loudness: L10n.text("eq.preset.loudness")
        case .smallSpeakers: L10n.text("eq.preset.small_speakers")
        case .headphones: L10n.text("eq.preset.headphones")
        case .custom: L10n.text("custom")
        }
    }

    var gains: [Double] {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: [6, 6, 5, 3, 1, 0, 0, 0, -1, -1]
        case .bassReduction: [-6, -5, -4, -2, -1, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
        case .trebleReduction: [0, 0, 0, 0, 0, -1, -2, -4, -5, -6]
        case .vocal: [-2, -2, -1, 0, 2, 4, 4, 3, 1, 0]
        case .vocalReduction: [2, 2, 1, -1, -3, -4, -3, -1, 0, 1]
        case .speech: [-4, -3, -1, 1, 4, 5, 5, 3, 0, -3]
        case .acoustic: [4, 4, 3, 1, 1, 1, 2, 3, 3, 2]
        case .classical: [0, 0, 0, 0, 0, 0, -3, -3, -3, -4]
        case .piano: [2, 1, 0, 2, 3, 1, 3, 4, 3, 3]
        case .jazz: [3, 2, 1, 2, -2, -2, 0, 1, 2, 3]
        case .lounge: [-3, -2, 0, 2, 3, 1, -1, 0, 1, 2]
        case .pop: [-1, 1, 3, 4, 3, 1, 0, -1, -1, -2]
        case .rnb: [3, 6, 5, 1, -2, -1, 2, 2, 3, 3]
        case .hipHop: [5, 4, 1, 3, -1, -1, 1, -1, 2, 3]
        case .dance: [6, 5, 2, 0, 0, -3, -4, -4, 0, 0]
        case .electronic: [5, 4, 2, 0, -1, 0, 2, 3, 5, 5]
        case .rock: [4, 3, 2, 0, -1, 1, 3, 4, 4, 3]
        case .metal: [4, 3, 0, -2, -4, -3, 0, 3, 5, 4]
        case .loudness: [6, 4, 0, -1, -1, -1, 0, 1, 4, 5]
        case .smallSpeakers: [5, 4, 3, 2, 1, 0, -1, -1, 0, 1]
        case .headphones: [3, 5, 3, -1, -1, 0, 2, 4, 5, 4]
        case .custom: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    var accentChoice: AppAccent {
        didSet { defaults.set(accentChoice.rawValue, forKey: Keys.accentChoice) }
    }
    var palette: AppPalette {
        didSet { defaults.set(palette.rawValue, forKey: Keys.palette) }
    }
    /// Page gradient of the current palette and appearance.
    var pageColors: [Color] {
        palette.background(for: theme).map(\.color)
    }
    /// Card / field surface of the current palette and appearance.
    var surfaceColor: Color {
        palette.surface(for: theme).color
    }
    /// What views tint with. Reading it (rather than `theme.accent`) is what
    /// makes a view redraw when the accent changes.
    var accentComponents: BubbleColorComponents {
        accentChoice.components(for: theme, on: palette)
    }
    var accent: Color { accentComponents.color }
    /// Label colour for anything filled with the accent.
    var onAccent: Color {
        accentComponents.prefersDarkForeground ? .black : .white
    }
    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    var textScale: AppTextScale {
        didSet { defaults.set(textScale.rawValue, forKey: Keys.textScale) }
    }
    /// Opens Home with the now-playing stage instead of going straight
    /// into shelves. The shelves stay exactly where they are underneath.
    var homeStageEnabled: Bool {
        didSet {
            defaults.set(homeStageEnabled, forKey: Keys.homeStageEnabled)
        }
    }
    /// Pins playback chrome to the flat pre-iOS 26 look: the full-screen
    /// player, the mini player and the tab bar it sits in. Below iOS 26
    /// everything already draws that way and the switch has nothing to do,
    /// so it is only offered where Liquid Glass actually applies.
    var classicChrome: Bool {
        didSet {
            defaults.set(classicChrome, forKey: Keys.classicChrome)
        }
    }
    var equalizerEnabled: Bool {
        didSet { defaults.set(equalizerEnabled, forKey: Keys.equalizer) }
    }
    var equalizerPreset: EqualizerPreset {
        didSet { defaults.set(equalizerPreset.rawValue, forKey: Keys.preset) }
    }
    var equalizerGains: [Double] {
        didSet { defaults.set(equalizerGains, forKey: Keys.gains) }
    }
    var equalizerPreamp: Double {
        didSet { defaults.set(equalizerPreamp, forKey: Keys.preamp) }
    }
    var preferHighQuality: Bool {
        didSet {
            defaults.set(preferHighQuality, forKey: Keys.preferHighQuality)
        }
    }
    var crossfadeDuration: Double {
        didSet {
            let normalized = PlaybackTransitionPolicy.normalizedDuration(crossfadeDuration)
            if normalized != crossfadeDuration { crossfadeDuration = normalized }
            defaults.set(normalized, forKey: "audio.crossfadeDuration")
        }
    }
    var vkBroadcastEnabled: Bool {
        didSet { defaults.set(vkBroadcastEnabled, forKey: "vk.broadcastEnabled") }
    }
    var vkReportingEnabled: Bool {
        didSet { defaults.set(vkReportingEnabled, forKey: "vk.reportingEnabled") }
    }
    var crossfadeEnabled: Bool {
        didSet {
            defaults.set(crossfadeEnabled, forKey: Keys.crossfadeEnabled)
        }
    }
    var mixMoodPreference: MixMoodPreference {
        didSet {
            defaults.set(
                mixMoodPreference.rawValue,
                forKey: Keys.mixMoodPreference
            )
        }
    }
    var mixLanguagePreference: MixLanguagePreference {
        didSet {
            defaults.set(
                mixLanguagePreference.rawValue,
                forKey: Keys.mixLanguagePreference
            )
        }
    }
    var mixFamiliarityPreference: MixFamiliarityPreference {
        didSet {
            defaults.set(
                mixFamiliarityPreference.rawValue,
                forKey: Keys.mixFamiliarityPreference
            )
        }
    }
    var loudnessNormalization: Bool {
        didSet {
            defaults.set(
                loudnessNormalization,
                forKey: Keys.loudnessNormalization
            )
        }
    }
    var dynamicRangeCompression: Bool {
        didSet {
            defaults.set(
                dynamicRangeCompression,
                forKey: Keys.dynamicRangeCompression
            )
        }
    }
    var spatialAudioEnabled: Bool {
        didSet {
            defaults.set(
                spatialAudioEnabled,
                forKey: Keys.spatialAudioEnabled
            )
        }
    }
    var spatialAudioIntensity: Double {
        didSet {
            let normalized = min(max(spatialAudioIntensity, 0), 1)
            if spatialAudioIntensity != normalized {
                spatialAudioIntensity = normalized
                return
            }
            defaults.set(normalized, forKey: Keys.spatialAudioIntensity)
        }
    }
    var resumeOnBluetoothConnection: Bool {
        didSet {
            defaults.set(
                resumeOnBluetoothConnection,
                forKey: Keys.resumeOnBluetoothConnection
            )
        }
    }
    var pauseAtMinimumVolume: Bool {
        didSet {
            defaults.set(
                pauseAtMinimumVolume,
                forKey: Keys.pauseAtMinimumVolume
            )
        }
    }
    var appVolume: Double {
        didSet {
            let normalized = min(max(appVolume, 0), 1)
            if appVolume != normalized {
                appVolume = normalized
                return
            }
            defaults.set(normalized, forKey: Keys.appVolume)
        }
    }
    var advanceOnPlaybackError: Bool {
        didSet {
            defaults.set(
                advanceOnPlaybackError,
                forKey: Keys.advanceOnPlaybackError
            )
        }
    }
    var offlineStorageLimitGB: Int {
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
    var automaticOfflineCacheEnabled: Bool {
        didSet {
            defaults.set(
                automaticOfflineCacheEnabled,
                forKey: Keys.automaticOfflineCacheEnabled
            )
        }
    }
    /// Save a track for offline playback right after it is liked. Wi-Fi
    /// only: a like must never spend mobile data on its own.
    var autoDownloadLikes: Bool {
        didSet {
            defaults.set(autoDownloadLikes, forKey: Keys.autoDownloadLikes)
        }
    }
    var hapticsEnabled: Bool {
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
        accentChoice = AppAccent(
            rawValue: defaults.string(forKey: Keys.accentChoice) ?? ""
        ) ?? .blue
        palette = AppPalette(
            rawValue: defaults.string(forKey: Keys.palette) ?? ""
        ) ?? .classic
        if settingsVersion < 4 {
            defaults.removeObject(forKey: LegacyKeys.liquidGlass)
            defaults.set(4, forKey: Keys.version)
        }
        textScale = AppTextScale(
            rawValue: defaults.string(forKey: Keys.textScale) ?? ""
        ) ?? .system
        homeStageEnabled = defaults.object(
            forKey: Keys.homeStageEnabled
        ) as? Bool ?? true
        // 3.28.82 shipped this as a player-only switch under its own key.
        classicChrome = defaults.object(forKey: Keys.classicChrome) as? Bool
            ?? defaults.object(
                forKey: LegacyKeys.classicPlayerChrome
            ) as? Bool
            ?? false
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
        crossfadeDuration = PlaybackTransitionPolicy.normalizedDuration(
            (defaults.object(forKey: "audio.crossfadeDuration") as? Double) ?? 0.55)
        vkBroadcastEnabled = defaults.bool(forKey: "vk.broadcastEnabled")
        vkReportingEnabled = defaults.bool(forKey: "vk.reportingEnabled")
        crossfadeEnabled = defaults.object(
            forKey: Keys.crossfadeEnabled
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
        autoDownloadLikes = defaults.object(
            forKey: Keys.autoDownloadLikes
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
        accentChoice = .blue
        palette = .classic
        textScale = .system
        classicChrome = false
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
        static let accentChoice = "appearance.accent"
        static let palette = "appearance.palette"
        static let appearance = "appearance.mode"
        static let textScale = "appearance.textScale"
        static let classicChrome = "appearance.classicChrome"
        static let homeStageEnabled = "home.stage.enabled"
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
        static let autoDownloadLikes = "offline.autoDownloadLikes"
        static let hapticsEnabled = "feedback.haptics.enabled"
        static let preferHighQuality = "audio.playback.preferHighQuality"
        static let crossfadeEnabled = "audio.playback.crossfadeEnabled"
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
        static let classicPlayerChrome = "appearance.player.classic"
    }
}

private struct AppTextScaleModifier: ViewModifier {
    let scale: AppTextScale
    @Environment(\.dynamicTypeSize) private var inheritedSize

    func body(content: Content) -> some View {
        if let range = AppTextScalePolicy.resolvedRange(
            for: scale,
            inherited: inheritedSize
        ) {
            content.dynamicTypeSize(range)
        } else {
            content
        }
    }
}

extension View {
    func appTextScale(_ scale: AppTextScale) -> some View {
        modifier(AppTextScaleModifier(scale: scale))
    }
}
