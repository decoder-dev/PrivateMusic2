import Foundation
import OSLog

/// Builds a ZIP archive (STORE, no compression) from in-memory entries.
enum ZipArchiveWriter {
    struct Entry: Sendable {
        let path: String
        let data: Data
        let modifiedAt: Date

        init(path: String, data: Data, modifiedAt: Date = Date()) {
            self.path = path
            self.data = data
            self.modifiedAt = modifiedAt
        }
    }

    static func archive(entries: [Entry]) throws -> Data {
        guard !entries.isEmpty else {
            throw LogArchiveError.emptyArchive
        }
        var payload = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let fileName = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let (modTime, modDate) = dosDateTime(entry.modifiedAt)

            var local = Data()
            local.appendUInt32(0x0403_4b50)
            local.appendUInt16(20)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt16(modTime)
            local.appendUInt16(modDate)
            local.appendUInt32(crc)
            local.appendUInt32(size)
            local.appendUInt32(size)
            local.appendUInt16(UInt16(fileName.count))
            local.appendUInt16(0)
            local.append(fileName)
            local.append(entry.data)

            payload.append(local)

            var central = Data()
            central.appendUInt32(0x0201_4b50)
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(modTime)
            central.appendUInt16(modDate)
            central.appendUInt32(crc)
            central.appendUInt32(size)
            central.appendUInt32(size)
            central.appendUInt16(UInt16(fileName.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(offset)
            central.append(fileName)
            centralDirectory.append(central)

            offset += UInt32(local.count)
        }

        let centralOffset = offset
        payload.append(centralDirectory)
        offset += UInt32(centralDirectory.count)

        var end = Data()
        end.appendUInt32(0x0605_4b50)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt32(UInt32(centralDirectory.count))
        end.appendUInt32(centralOffset)
        end.appendUInt16(0)
        payload.append(end)
        return payload
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let dosYear = UInt16(clamping: max(0, min(127, (parts.year ?? 1980) - 1980)))
        let month = UInt16(clamping: max(1, min(12, parts.month ?? 1)))
        let day = UInt16(clamping: max(1, min(31, parts.day ?? 1)))
        let hour = UInt16(clamping: max(0, min(23, parts.hour ?? 0)))
        let minute = UInt16(clamping: max(0, min(59, parts.minute ?? 0)))
        let second = UInt16(clamping: max(0, min(59, (parts.second ?? 0) / 2)))
        let dosTime = hour << 11 | minute << 5 | second
        let dosDate = dosYear << 9 | month << 5 | day
        return (dosTime, dosDate)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xffff_ffff
    }

    private static let table: [UInt32] = {
        (0 ..< 256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) == 1
                    ? (value >> 1) ^ 0xedb8_8320
                    : value >> 1
            }
            return value
        }
    }()
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

enum LogArchiveError: Error, Equatable, LocalizedError {
    case emptyArchive
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .emptyArchive:
            L10n.text("developer.log_archive_empty")
        case .writeFailed:
            L10n.text("developer.log_archive_write_failed")
        }
    }
}

actor LogArchiveService {
    static let shared = LogArchiveService()

    private let fileManager: FileManager
    private let appLog: AppLog

    init(
        fileManager: FileManager = .default,
        appLog: AppLog = .shared
    ) {
        self.fileManager = fileManager
        self.appLog = appLog
    }

    func buildArchive(
        diagnostics: DeveloperDiagnosticsSnapshot
    ) async throws -> URL {
        appLog.info(.app, "Building developer log archive")
        var entries: [ZipArchiveWriter.Entry] = []

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifest = try encoder.encode(diagnostics)
        entries.append(
            ZipArchiveWriter.Entry(path: "manifest.json", data: manifest)
        )

        let logFiles = appLog.listLogFiles()
        if logFiles.isEmpty {
            let placeholder = Data(
                "No file logs yet. Enable file logging or use the app for a while.\n"
                    .utf8
            )
            entries.append(
                ZipArchiveWriter.Entry(
                    path: "logs/README.txt",
                    data: placeholder
                )
            )
        } else {
            for url in logFiles {
                let data = try Data(contentsOf: url)
                entries.append(
                    ZipArchiveWriter.Entry(
                        path: "logs/\(url.lastPathComponent)",
                        data: data,
                        modifiedAt: (try? url.resourceValues(
                            forKeys: [.contentModificationDateKey]
                        ).contentModificationDate) ?? Date()
                    )
                )
            }
        }

        if let osLog = try? await exportUnifiedLog() {
            entries.append(
                ZipArchiveWriter.Entry(
                    path: "oslog/unified.log.txt",
                    data: osLog
                )
            )
        }

        if let bootLog = try? await exportUnifiedLog(
            timeIntervalSinceLatestBoot: 60 * 60 * 24 * 7
        ) {
            entries.append(
                ZipArchiveWriter.Entry(
                    path: "oslog/unified.boot-window.log.txt",
                    data: bootLog
                )
            )
        }

        let zipData = try ZipArchiveWriter.archive(entries: entries)
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("PrivateMusicLogs", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let archiveURL = directory.appendingPathComponent(
            "PrivateMusic-logs-\(stamp).zip"
        )
        do {
            try zipData.write(to: archiveURL, options: .atomic)
        } catch {
            throw LogArchiveError.writeFailed
        }
        appLog.info(.app, "Developer log archive ready (\(zipData.count) bytes)")
        return archiveURL
    }

    func removeArchive(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    private func exportUnifiedLog(
        timeIntervalSinceLatestBoot: TimeInterval = 60 * 60 * 24
    ) async throws -> Data {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(
            timeIntervalSinceLatestBoot: timeIntervalSinceLatestBoot
        )
        let entries = try store.getEntries(at: position)
        var lines: [String] = []
        lines.reserveCapacity(1024)
        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            guard log.subsystem == AppLog.subsystem else { continue }
            let stamp = ISO8601DateFormatter().string(from: log.date)
            let level = log.level.rawValue
            lines.append(
                "\(stamp) [\(level)][\(log.category)] \(log.composedMessage)"
            )
        }
        if lines.isEmpty {
            lines.append(
                "No unified log entries for \(AppLog.subsystem) in the requested boot window (\(Int(timeIntervalSinceLatestBoot))s)."
            )
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
