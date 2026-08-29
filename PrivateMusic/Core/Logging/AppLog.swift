import Foundation
import OSLog

enum AppLogCategory: String, CaseIterable, Sendable {
    case app
    case session
    case network
    case api
    case player
    case hls
    case downloads
    case mix
}

enum AppLogLevel: String, Sendable, Comparable {
    case debug
    case info
    case error

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .error: .error
        }
    }

    static func < (lhs: AppLogLevel, rhs: AppLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .error: 2
        }
    }
}

/// File + unified logging sink. Log files live under Application Support so
/// they survive restarts and can be bundled into a developer archive.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    static let subsystem = Bundle.main.bundleIdentifier
        ?? "com.dec.privatemusic2"

    private let queue = DispatchQueue(label: "com.dec.privatemusic2.applog")
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private var loggers: [AppLogCategory: Logger] = [:]

    private(set) var isFileLoggingEnabled: Bool
    private(set) var isVerbose: Bool

    private init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.isFileLoggingEnabled = defaults.object(
            forKey: Keys.fileLoggingEnabled
        ) as? Bool ?? DeveloperFeature.isUnlocked
        self.isVerbose = defaults.object(
            forKey: Keys.verboseLogging
        ) as? Bool ?? true
        for category in AppLogCategory.allCases {
            loggers[category] = Logger(
                subsystem: Self.subsystem,
                category: category.rawValue
            )
        }
    }

    func bootstrap() {
        queue.sync {
            try? ensureLogsDirectory()
        }
        info(.app, Self.launchSummary())
    }

    func setFileLoggingEnabled(_ enabled: Bool) {
        queue.sync {
            isFileLoggingEnabled = enabled
            defaults.set(enabled, forKey: Keys.fileLoggingEnabled)
            if enabled {
                try? ensureLogsDirectory()
            }
        }
    }

    func setVerbose(_ enabled: Bool) {
        queue.sync {
            isVerbose = enabled
            defaults.set(enabled, forKey: Keys.verboseLogging)
        }
    }

    func debug(_ category: AppLogCategory, _ message: String) {
        write(category: category, level: .debug, message: message)
    }

    func info(_ category: AppLogCategory, _ message: String) {
        write(category: category, level: .info, message: message)
    }

    func error(_ category: AppLogCategory, _ message: String) {
        write(category: category, level: .error, message: message)
    }

    func listLogFiles() -> [URL] {
        queue.sync {
            guard let directory = try? logsDirectoryURL(),
                  let names = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                return []
            }
            return names
                .filter { $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    func totalLogBytes() -> Int64 {
        listLogFiles().reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize) ?? 0
            total += Int64(size)
        }
    }

    func clearLogFiles() throws {
        try queue.sync {
            let directory = try logsDirectoryURL()
            guard fileManager.fileExists(atPath: directory.path) else {
                return
            }
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            for file in files where file.pathExtension == "log" {
                try fileManager.removeItem(at: file)
            }
        }
        info(.app, "Developer log files cleared")
    }

    // MARK: - Private

    private func write(
        category: AppLogCategory,
        level: AppLogLevel,
        message: String
    ) {
        guard shouldPersist(level: level) else {
            loggers[category]?.log(level: level.osLogType, "\(message, privacy: .public)")
            return
        }
        let redacted = AppLogRedaction.redact(message)
        let line = Self.formatLine(
            category: category,
            level: level,
            message: redacted,
            date: Date(),
            verbose: isVerbose
        )
        loggers[category]?.log(level: level.osLogType, "\(redacted, privacy: .public)")
        queue.async { [self] in
            guard isFileLoggingEnabled else { return }
            do {
                try append(line, category: category)
            } catch {
                loggers[.app]?.error(
                    "AppLog file write failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func shouldPersist(level: AppLogLevel) -> Bool {
        if level == .error { return true }
        if level == .info { return true }
        return isVerbose
    }

    private func append(_ line: String, category: AppLogCategory) throws {
        try ensureLogsDirectory()
        let unified = try activeLogFileURL()
        try appendLine(line, to: unified)
        try rotateIfNeeded(activeLog: unified)

        if isVerbose {
            let categoryURL = try logsDirectoryURL().appendingPathComponent(
                "\(category.rawValue).log"
            )
            try appendLine(line, to: categoryURL)
            try rotateIfNeeded(activeLog: categoryURL, prefix: category.rawValue)
        }
    }

    private func appendLine(_ line: String, to url: URL) throws {
        let payload = Data((line + "\n").utf8)
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeeded(
        activeLog url: URL,
        prefix: String = "PrivateMusic"
    ) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > Self.maxActiveLogBytes else {
            return
        }
        let rotated = try logsDirectoryURL().appendingPathComponent(
            "\(prefix)-\(Self.timestamp(Date())).log"
        )
        try fileManager.moveItem(at: url, to: rotated)
        try pruneOldLogs(prefix: prefix)
    }

    private func pruneOldLogs(prefix: String) throws {
        let directory = try logsDirectoryURL()
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let rotated = files
            .filter { $0.lastPathComponent.hasPrefix("\(prefix)-") }
            .sorted {
                let left = (try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return left > right
            }
        for stale in rotated.dropFirst(Self.maxRotatedLogFiles) {
            try? fileManager.removeItem(at: stale)
        }
    }

    private func ensureLogsDirectory() throws {
        let directory = try logsDirectoryURL()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func logsDirectoryURL() throws -> URL {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppLogError.missingApplicationSupport
        }
        return support
            .appendingPathComponent("PrivateMusic", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    private func activeLogFileURL() throws -> URL {
        try logsDirectoryURL().appendingPathComponent("PrivateMusic.log")
    }

    static func formatLine(
        category: AppLogCategory,
        level: AppLogLevel,
        message: String,
        date: Date,
        verbose: Bool
    ) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        if verbose {
            let thread = Thread.isMainThread ? "main" : "bg"
            return "\(stamp) [\(level.rawValue.uppercased())][\(category.rawValue)][\(thread)] \(message)"
        }
        return "\(stamp) [\(level.rawValue.uppercased())][\(category.rawValue)] \(message)"
    }

    private static func launchSummary() -> String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        let memory = ProcessInfo.processInfo.physicalMemory / 1_000_000
        return """
        App launched version=\(version) build=\(build) \
        os=\(ProcessInfo.processInfo.operatingSystemVersionString) \
        locale=\(Locale.current.identifier) \
        memoryMB=\(memory) \
        verbose=\(shared.isVerbose) fileLogging=\(shared.isFileLoggingEnabled)
        """
    }

    private static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 1970,
            parts.month ?? 1,
            parts.day ?? 1,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    private static let maxActiveLogBytes = 10_000_000
    private static let maxRotatedLogFiles = 24

    private enum Keys {
        static let fileLoggingEnabled = "developer.log.fileLoggingEnabled"
        static let verboseLogging = "developer.log.verboseLogging"
    }
}

enum AppLogError: Error {
    case missingApplicationSupport
}
