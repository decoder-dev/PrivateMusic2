import Foundation
import OSLog

enum AppLogCategory: String, CaseIterable, Sendable {
    case app
    case session
    case network
    case player
    case hls
}

enum AppLogLevel: String, Sendable {
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

    private init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.isFileLoggingEnabled = defaults.object(
            forKey: Keys.fileLoggingEnabled
        ) as? Bool ?? DeveloperFeature.isUnlocked
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
        info(.app, "App launched")
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
        let line = Self.formatLine(
            category: category,
            level: level,
            message: message,
            date: Date()
        )
        loggers[category]?.log(level: level.osLogType, "\(message, privacy: .public)")
        queue.async { [self] in
            guard isFileLoggingEnabled else { return }
            do {
                try append(line)
            } catch {
                loggers[.app]?.error(
                    "AppLog file write failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func append(_ line: String) throws {
        try ensureLogsDirectory()
        let url = try activeLogFileURL()
        let payload = Data((line + "\n").utf8)
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: url, options: .atomic)
        }
        try rotateIfNeeded(activeLog: url)
    }

    private func rotateIfNeeded(activeLog url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > Self.maxActiveLogBytes else {
            return
        }
        let rotated = try logsDirectoryURL().appendingPathComponent(
            "PrivateMusic-\(Self.timestamp(Date())).log"
        )
        try fileManager.moveItem(at: url, to: rotated)
        try pruneOldLogs()
    }

    private func pruneOldLogs() throws {
        let directory = try logsDirectoryURL()
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let rotated = files
            .filter { $0.lastPathComponent.hasPrefix("PrivateMusic-") }
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
        date: Date
    ) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        return "\(stamp) [\(level.rawValue.uppercased())][\(category.rawValue)] \(message)"
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

    private static let maxActiveLogBytes = 2_000_000
    private static let maxRotatedLogFiles = 8

    private enum Keys {
        static let fileLoggingEnabled = "developer.log.fileLoggingEnabled"
    }
}

enum AppLogError: Error {
    case missingApplicationSupport
}
