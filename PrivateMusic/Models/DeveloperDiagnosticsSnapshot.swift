import Foundation

struct DeveloperDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let capturedAt: Date
    let appVersion: String
    let buildNumber: String
    let bundleIdentifier: String
    let deviceModel: String
    let systemVersion: String
    let localeIdentifier: String
    let networkStatus: String
    let networkState: String
    let networkTransport: String
    let sessionActive: Bool
    let sessionExpiresAt: Date?
    let sessionCanRefresh: Bool
    let currentTrackID: String?
    let currentTrackTitle: String?
    let currentTrackArtist: String?
    let isPlaying: Bool
    let isBuffering: Bool
    let queueLength: Int
    let queueIndex: Int?
    let shuffleEnabled: Bool
    let fileLogCount: Int
    let totalLogBytes: Int64
    let developerMenuUnlocked: Bool
    let fileLoggingEnabled: Bool
    let verboseLoggingEnabled: Bool
    let settings: DeveloperSettingsSnapshot
}

struct DeveloperSettingsSnapshot: Codable, Equatable, Sendable {
    let appearance: String
    let theme: String
    let textScale: String
    let homeStageEnabled: Bool
    let classicChrome: Bool
    let preferHighQuality: Bool
    let crossfadeEnabled: Bool
    let loudnessNormalization: Bool
    let equalizerEnabled: Bool
    let equalizerPreset: String
    let mixMoodPreference: String
    let mixLanguagePreference: String
    let mixFamiliarityPreference: String
    let selenaDiversityPreference: String
    let offlineStorageLimitGB: Int
    let automaticOfflineCacheEnabled: Bool
    let hapticsEnabled: Bool
    let advanceOnPlaybackError: Bool
}

enum DeveloperDiagnosticsBuilder {
    static func make(
        networkStatus: String,
        networkState: String,
        networkTransport: String,
        sessionActive: Bool,
        sessionExpiresAt: Date?,
        sessionCanRefresh: Bool,
        currentTrackID: String?,
        currentTrackTitle: String?,
        currentTrackArtist: String?,
        isPlaying: Bool,
        isBuffering: Bool,
        queueLength: Int,
        queueIndex: Int?,
        shuffleEnabled: Bool,
        fileLogCount: Int,
        totalLogBytes: Int64,
        developerMenuUnlocked: Bool,
        fileLoggingEnabled: Bool,
        verboseLoggingEnabled: Bool,
        settings: DeveloperSettingsSnapshot,
        bundle: Bundle = .main,
        deviceModel: String = Self.deviceModelIdentifier(),
        systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        localeIdentifier: String = Locale.current.identifier,
        capturedAt: Date = Date()
    ) -> DeveloperDiagnosticsSnapshot {
        DeveloperDiagnosticsSnapshot(
            capturedAt: capturedAt,
            appVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "—",
            buildNumber: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "—",
            bundleIdentifier: bundle.bundleIdentifier ?? "—",
            deviceModel: deviceModel,
            systemVersion: systemVersion,
            localeIdentifier: localeIdentifier,
            networkStatus: networkStatus,
            networkState: networkState,
            networkTransport: networkTransport,
            sessionActive: sessionActive,
            sessionExpiresAt: sessionExpiresAt,
            sessionCanRefresh: sessionCanRefresh,
            currentTrackID: currentTrackID,
            currentTrackTitle: currentTrackTitle,
            currentTrackArtist: currentTrackArtist,
            isPlaying: isPlaying,
            isBuffering: isBuffering,
            queueLength: queueLength,
            queueIndex: queueIndex,
            shuffleEnabled: shuffleEnabled,
            fileLogCount: fileLogCount,
            totalLogBytes: totalLogBytes,
            developerMenuUnlocked: developerMenuUnlocked,
            fileLoggingEnabled: fileLoggingEnabled,
            verboseLoggingEnabled: verboseLoggingEnabled,
            settings: settings
        )
    }

    static func settingsSnapshot(from settings: AppSettings) -> DeveloperSettingsSnapshot {
        DeveloperSettingsSnapshot(
            appearance: settings.appearance.rawValue,
            theme: settings.theme.rawValue,
            textScale: settings.textScale.rawValue,
            homeStageEnabled: settings.homeStageEnabled,
            classicChrome: settings.classicChrome,
            preferHighQuality: settings.preferHighQuality,
            crossfadeEnabled: settings.crossfadeEnabled,
            loudnessNormalization: settings.loudnessNormalization,
            equalizerEnabled: settings.equalizerEnabled,
            equalizerPreset: settings.equalizerPreset.rawValue,
            mixMoodPreference: settings.mixMoodPreference.rawValue,
            mixLanguagePreference: settings.mixLanguagePreference.rawValue,
            mixFamiliarityPreference: settings.mixFamiliarityPreference.rawValue,
            selenaDiversityPreference: settings.selenaDiversityPreference.rawValue,
            offlineStorageLimitGB: settings.offlineStorageLimitGB,
            automaticOfflineCacheEnabled: settings.automaticOfflineCacheEnabled,
            hapticsEnabled: settings.hapticsEnabled,
            advanceOnPlaybackError: settings.advanceOnPlaybackError
        )
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { cString in
                String(cString: cString)
            }
        }
    }
}
