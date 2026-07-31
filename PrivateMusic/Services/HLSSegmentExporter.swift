import AVFoundation
import CommonCrypto
import Foundation

/// Builds a single M4A file from an HLS (m3u8) source without relying on
/// `AVAssetExportSession`. AVFoundation refuses to export many VK HLS
/// assets (and every offline `.movpkg` package), so segments are downloaded
/// manually, decrypted (AES-128 CBC per RFC 8216), stitched into an MPEG-TS
/// stream and remuxed into `.m4a` through `AVAssetReader`/`AVAssetWriter`.
///
/// The approach mirrors the reference Python implementation used by
/// VKpyMusic (`vkpymusic/utils/m3u8converter.py`):
/// https://github.com/issamansur/vkpymusic
actor HLSSegmentExporter {
    static let maximumStitchedSize: Int64 = 150_000_000

    private let session: URLSession
    private let fileManager: FileManager
    private let segmentLimit = 4000

    init(session: URLSession? = nil, fileManager: FileManager = .default) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: configuration)
        }
        self.fileManager = fileManager
    }

    /// Exports a remote HLS stream (`index.m3u8` URL) into an M4A file.
    func exportToM4A(
        streamURL: URL,
        headers: [String: String],
        destination: URL,
        fileSizeLimit: Int64
    ) async throws {
        let playlistData = try await fetchData(
            from: streamURL,
            headers: headers
        )
        guard let playlistText = String(data: playlistData, encoding: .utf8),
              playlistText.contains("#EXTM3U") else {
            throw HLSExportError.invalidPlaylist
        }

        let baseURL = streamURL.deletingLastPathComponent()
        let mediaPlaylist: String
        let mediaBaseURL: URL
        if let variantURL = bestVariantURL(
            in: playlistText,
            baseURL: baseURL
        ) {
            mediaBaseURL = variantURL.deletingLastPathComponent()
            let variantData = try await fetchData(from: variantURL, headers: headers)
            guard let text = String(data: variantData, encoding: .utf8),
                  text.contains("#EXTM3U") else {
                throw HLSExportError.invalidPlaylist
            }
            mediaPlaylist = text
        } else {
            mediaPlaylist = playlistText
            mediaBaseURL = baseURL
        }

        let parsed = try parseSegments(
            in: mediaPlaylist,
            baseURL: mediaBaseURL
        )
        guard !parsed.segments.isEmpty else {
            throw HLSExportError.emptyPlaylist
        }

        let stagingDirectory = destination
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let stitchedURL = stagingDirectory
            .appendingPathComponent("stream.ts")
        fileManager.createFile(atPath: stitchedURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: stitchedURL)
        defer { try? handle.close() }

        var keyCache: [URL: Data] = [:]
        var written: Int64 = 0
        for (index, segment) in parsed.segments.enumerated() {
            try Task.checkCancellation()
            var data = try await fetchData(
                from: segment.url,
                headers: headers,
                byteRange: segment.byteRange
            )
            if let keyInfo = segment.key {
                let keyData: Data
                if let cached = keyCache[keyInfo.url] {
                    keyData = cached
                } else {
                    keyData = try await fetchData(
                        from: keyInfo.url,
                        headers: headers
                    )
                    keyCache[keyInfo.url] = keyData
                }
                data = try decryptSegment(
                    data,
                    key: keyData,
                    iv: keyInfo.iv(parsed.mediaSequence + index)
                )
            }
            written += Int64(data.count)
            guard written <= Self.maximumStitchedSize,
                  written <= fileSizeLimit else {
                throw HLSExportError.fileTooLarge
            }
            try handle.write(contentsOf: data)
        }
        try handle.synchronize()

        do {
            try await remuxToM4A(source: stitchedURL, destination: destination)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
        try? fileManager.removeItem(at: stagingDirectory)
    }

    /// Exports an offline `.movpkg` HLS bundle produced by
    /// `AVAssetDownloadTask` into an M4A file. Fragments inside the package
    /// are already unencrypted MPEG-TS and only require stitching + remux.
    func exportMovpkgToM4A(
        packageURL: URL,
        destination: URL,
        fileSizeLimit: Int64
    ) async throws {
        let fragmentURLs = try collectFragments(in: packageURL)
        guard !fragmentURLs.isEmpty else {
            throw HLSExportError.noFragments
        }

        let stagingDirectory = destination
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let stitchedURL = stagingDirectory
            .appendingPathComponent("stream.ts")
        fileManager.createFile(atPath: stitchedURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: stitchedURL)
        defer { try? handle.close() }

        var written: Int64 = 0
        for fragmentURL in fragmentURLs {
            try Task.checkCancellation()
            let data = try Data(contentsOf: fragmentURL)
            written += Int64(data.count)
            guard written <= Self.maximumStitchedSize,
                  written <= fileSizeLimit else {
                throw HLSExportError.fileTooLarge
            }
            try handle.write(contentsOf: data)
        }
        try handle.synchronize()

        do {
            try await remuxToM4A(source: stitchedURL, destination: destination)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
        try? fileManager.removeItem(at: stagingDirectory)
    }

    // MARK: - Playlist parsing

    private struct EncryptionKey {
        let url: URL
        let explicitIV: Data?

        func iv(_ segmentNumber: Int) -> Data {
            if let explicitIV {
                return explicitIV
            }
            var bigEndian = UInt64(segmentNumber).bigEndian
            let highBytes = withUnsafeBytes(of: &bigEndian) { Data($0) }
            return Data(repeating: 0, count: 8) + highBytes
        }
    }

    private struct Segment {
        let url: URL
        let byteRange: Range<Int>?
        let key: EncryptionKey?
    }

    private func bestVariantURL(
        in playlist: String,
        baseURL: URL
    ) -> URL? {
        let lines = playlist.components(separatedBy: .newlines)
        var bestBandwidth = -1
        var bestURL: URL?
        var pendingBandwidth: Int?
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = bandwidthValue(in: line)
                continue
            }
            guard !line.hasPrefix("#"), !line.isEmpty else { continue }
            if let bandwidth = pendingBandwidth {
                if bandwidth > bestBandwidth {
                    bestBandwidth = bandwidth
                    bestURL = resolvedURL(line, base: baseURL)
                }
                pendingBandwidth = nil
            }
        }
        return bestURL
    }

    private func parseSegments(
        in playlist: String,
        baseURL: URL
    ) throws -> (segments: [Segment], mediaSequence: Int) {
        var segments: [Segment] = []
        var mediaSequence = 0
        var currentKey: EncryptionKey?
        var pendingByteRange: Range<Int>?
        var byteRangeOffset = 0

        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence =
                    Int(line.replacingOccurrences(
                        of: "#EXT-X-MEDIA-SEQUENCE:",
                        with: ""
                    )) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                currentKey = parseKey(line, baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = parseByteRange(
                    line,
                    offset: &byteRangeOffset
                )
            } else if !line.hasPrefix("#"), !line.isEmpty {
                guard segments.count < segmentLimit else {
                    throw HLSExportError.tooManySegments
                }
                segments.append(Segment(
                    url: resolvedURL(line, base: baseURL),
                    byteRange: pendingByteRange,
                    key: currentKey
                ))
                pendingByteRange = nil
            }
        }
        return (segments, mediaSequence)
    }

    private func parseKey(_ line: String, baseURL: URL) -> EncryptionKey? {
        guard line.contains("METHOD=AES-128"),
              let uriMatch = line.range(of: "URI=\""),
              let endQuote = line[uriMatch.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        let uri = String(line[uriMatch.upperBound..<endQuote])
        let keyURL = resolvedURL(uri, base: baseURL)

        var explicitIV: Data?
        if let ivMatch = line.range(of: "IV=0x")
            ?? line.range(of: "IV=0X") {
            var hex = String(line[ivMatch.upperBound...])
            if let comma = hex.firstIndex(of: ",") {
                hex = String(hex[..<comma])
            }
            if hex.count % 2 == 1 { hex = "0" + hex }
            var bytes = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                if let byte = UInt8(hex[index..<next], radix: 16) {
                    bytes.append(byte)
                }
                index = next
            }
            if bytes.count == 16 {
                explicitIV = bytes
            }
        }
        return EncryptionKey(url: keyURL, explicitIV: explicitIV)
    }

    private func parseByteRange(
        _ line: String,
        offset: inout Int
    ) -> Range<Int>? {
        let value = line.replacingOccurrences(
            of: "#EXT-X-BYTERANGE:",
            with: ""
        )
        let parts = value.split(separator: "@")
        guard let length = Int(parts.first ?? "") else { return nil }
        let start: Int
        if parts.count > 1, let explicit = Int(parts[1]) {
            start = explicit
        } else {
            start = offset
        }
        offset = start + length
        return start..<(start + length)
    }

    private func bandwidthValue(in line: String) -> Int {
        guard let range = line.range(of: "BANDWIDTH=") else { return 0 }
        var value = String(line[range.upperBound...])
        if let comma = value.firstIndex(of: ",") {
            value = String(value[..<comma])
        }
        return Int(value) ?? 0
    }

    private func resolvedURL(_ string: String, base: URL) -> URL {
        if let absolute = URL(string: string), absolute.scheme != nil {
            return absolute
        }
        return base.appendingPathComponent(string)
    }

    // MARK: - Networking

    private func fetchData(
        from url: URL,
        headers: [String: String],
        byteRange: Range<Int>? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let byteRange {
            request.setValue(
                "bytes=\(byteRange.lowerBound)-\(byteRange.upperBound - 1)",
                forHTTPHeaderField: "Range"
            )
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw HLSExportError.network
        }
        return data
    }

    // MARK: - Crypto (AES-128 CBC per RFC 8216)

    private func decryptSegment(
        _ data: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw HLSExportError.decryptionFailed
        }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outputBytes.baseAddress,
                            output.count,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw HLSExportError.decryptionFailed
        }
        return output.prefix(outputLength)
    }

    // MARK: - .movpkg handling

    private func collectFragments(in packageURL: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var fragments: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard values?.isRegularFile == true,
                  (values?.fileSize ?? 0) > 188 else {
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ext != "plist", ext != "json", ext != "xml",
                  ext != "m3u8", ext != "txt" else {
                continue
            }
            guard isMPEGTS(url) else { continue }
            fragments.append(url)
        }
        return fragments.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    /// MPEG-TS packets are 188 bytes long and start with the 0x47 sync byte.
    private func isMPEGTS(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 189),
              head.count >= 1,
              head[head.startIndex] == 0x47 else {
            return false
        }
        if head.count > 188 {
            return head[head.index(head.startIndex, offsetBy: 188)] == 0x47
        }
        return true
    }

    // MARK: - Remux MPEG-TS → M4A

    private func remuxToM4A(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first
        else {
            throw HLSExportError.noAudioTrack
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw HLSExportError.remuxFailed
        }
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(readerOutput) else {
            throw HLSExportError.remuxFailed
        }
        reader.add(readerOutput)

        guard let writer = try? AVAssetWriter(
            outputURL: destination,
            fileType: .m4a
        ) else {
            throw HLSExportError.remuxFailed
        }
        let formatHint: CMFormatDescription? =
            track.formatDescriptions.first.flatMap { description in
                unsafeDowncast(
                    description as AnyObject,
                    to: CMFormatDescription.self
                )
            }
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: formatHint
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw HLSExportError.remuxFailed
        }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            throw HLSExportError.remuxFailed
        }
        writer.startSession(atSourceTime: .zero)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "PrivateMusic.HLSRemux")
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        if Task.isCancelled {
                            writerInput.markAsFinished()
                            writer.cancelWriting()
                            reader.cancelReading()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        guard let sample = readerOutput.copyNextSampleBuffer() else {
                            writerInput.markAsFinished()
                            writer.finishWriting {
                                switch writer.status {
                                case .completed:
                                    continuation.resume(returning: ())
                                default:
                                    continuation.resume(
                                        throwing: writer.error
                                            ?? HLSExportError.remuxFailed
                                    )
                                }
                            }
                            return
                        }
                        if !writerInput.append(sample) {
                            writerInput.markAsFinished()
                            writer.cancelWriting()
                            reader.cancelReading()
                            continuation.resume(
                                throwing: writer.error
                                    ?? HLSExportError.remuxFailed
                            )
                            return
                        }
                    }
                }
            }
        } onCancel: {
            reader.cancelReading()
            writer.cancelWriting()
        }
    }
}

enum HLSExportError: LocalizedError {
    case invalidPlaylist
    case emptyPlaylist
    case tooManySegments
    case network
    case fileTooLarge
    case decryptionFailed
    case noFragments
    case noAudioTrack
    case remuxFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlaylist, .emptyPlaylist, .tooManySegments:
            return L10n.text("VK вернул неполный HLS-плейлист.")
        case .network:
            return L10n.text("Не удалось скачать сегменты потока.")
        case .fileTooLarge:
            return L10n.text("Файл больше 150 МБ.")
        case .decryptionFailed:
            return L10n.text("Не удалось расшифровать сегменты потока.")
        case .noFragments, .noAudioTrack, .remuxFailed:
            return L10n.text("Не удалось собрать аудиофайл.")
        }
    }
}
