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
    let sessionActive: Bool
    let sessionExpiresAt: Date?
    let currentTrackTitle: String?
    let isPlaying: Bool
    let fileLogCount: Int
    let totalLogBytes: Int64
    let developerMenuUnlocked: Bool
    let fileLoggingEnabled: Bool
}

enum DeveloperDiagnosticsBuilder {
    static func make(
        networkStatus: String,
        sessionActive: Bool,
        sessionExpiresAt: Date?,
        currentTrackTitle: String?,
        isPlaying: Bool,
        fileLogCount: Int,
        totalLogBytes: Int64,
        developerMenuUnlocked: Bool,
        fileLoggingEnabled: Bool,
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
            sessionActive: sessionActive,
            sessionExpiresAt: sessionExpiresAt,
            currentTrackTitle: currentTrackTitle,
            isPlaying: isPlaying,
            fileLogCount: fileLogCount,
            totalLogBytes: totalLogBytes,
            developerMenuUnlocked: developerMenuUnlocked,
            fileLoggingEnabled: fileLoggingEnabled
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
