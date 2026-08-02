import AVFoundation
import CommonCrypto
import Foundation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier
        ?? "com.dec.privatemusic2",
    category: "HLSExporter"
)

/// Builds a single M4A file from an HLS (m3u8) source without relying on
/// `AVAssetExportSession`. AVFoundation refuses to export many VK HLS
/// assets (and every offline `.movpkg` package), so segments are downloaded
/// manually, decrypted (AES-128 CBC per RFC 8216), stitched into a
/// container-aware source file and transcoded into `.m4a` (PCM → AAC)
/// through `AVAssetReader`/`AVAssetWriter`.
///
/// Supported segment containers:
/// - MPEG-TS (188/192/204 byte packets);
/// - fragmented MP4 / CMAF (`#EXT-X-MAP` with `ftyp`+`moov` init and
///   `moof`/`mdat` fragments);
/// - ADTS AAC;
/// - MP3.
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
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: configuration)
        }
        self.fileManager = fileManager
    }

    // MARK: - Public API

    /// Exports a remote HLS stream (`index.m3u8` URL) into an M4A file.
    ///
    /// Progress reports exact counters: `0/total` right after the media
    /// playlist is parsed, `index + 1/total` after every segment write and
    /// `.convertingToM4A` once the stitched source is handed to the
    /// transcode step. Every failure path — manifest, variant, segment, key,
    /// decrypt, write, size, cancellation and transcode — removes the staging
    /// directory and the destination via cleanup blocks.
    func exportToM4A(
        streamURL: URL,
        headers: [String: String],
        destination: URL,
        fileSizeLimit: Int64,
        progress: TrackExportProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        let media = try await resolveMediaPlaylist(
            from: streamURL,
            headers: headers
        )
        let parsed = try parseSegments(
            in: media.playlist,
            baseURL: media.baseURL
        )
        guard !parsed.segments.isEmpty else {
            throw HLSExportError.emptyPlaylist
        }
        let totalSegments = parsed.segments.count
        logger.info(
            "HLS export: \(totalSegments) segments, mediaSequence \(parsed.mediaSequence), map \(parsed.segments.first?.initialization != nil)"
        )

        await progress?(
            .downloadingSegments(completed: 0, total: totalSegments)
        )

        var keyCache: [URL: Data] = [:]
        var initializationCache: [InitializationCacheKey: Data] = [:]
        var nextOffsetByURL: [URL: Int] = [:]

        let firstSegment = parsed.segments[0]
        let firstInitialization = firstSegment.initialization
        let initializationData: Data?
        if let initialization = firstInitialization {
            initializationData = try await fetchInitialization(
                initialization,
                headers: headers,
                keyCache: &keyCache,
                cache: &initializationCache,
                nextOffsetByURL: &nextOffsetByURL
            )
            logger.info(
                "HLS export: init fetched, \(initializationData?.count ?? 0) bytes"
            )
        } else {
            initializationData = nil
        }

        var firstSegmentData = try await fetchSegment(
            firstSegment,
            mediaSequence: parsed.mediaSequence,
            index: 0,
            headers: headers,
            keyCache: &keyCache,
            nextOffsetByURL: &nextOffsetByURL
        )
        let container = try Self.detectContainer(
            initializationData: initializationData,
            firstSegmentData: firstSegmentData
        )
        logger.info(
            "HLS export: container \(container.rawValue), magic \(Self.magicPrefix(firstSegmentData))"
        )

        if container == .fragmentedMP4 {
            guard let initializationData else {
                throw HLSExportError.missingInitializationSection
            }
            try await exportCMAFToM4A(
                initializationData: initializationData,
                firstInitialization: firstInitialization,
                firstSegmentData: firstSegmentData,
                segments: parsed.segments,
                mediaSequence: parsed.mediaSequence,
                headers: headers,
                destination: destination,
                fileSizeLimit: fileSizeLimit,
                keyCache: &keyCache,
                nextOffsetByURL: &nextOffsetByURL,
                progress: progress
            )
            return
        }

        // Linear containers (MPEG-TS / ADTS / MP3) are stitched into one
        // file and decoded with AVAssetReader/AVAssetWriter, which handles
        // their loosely structured formats well.
        let stagingDirectory = destination
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }
        let sourceURL = stagingDirectory
            .appendingPathComponent("source")
            .appendingPathExtension(container.stagingExtension)
        guard fileManager.createFile(
            atPath: sourceURL.path,
            contents: nil
        ) else {
            throw HLSExportError.cannotCreateStagingFile
        }
        let handle = try FileHandle(forWritingTo: sourceURL)
        defer { try? handle.close() }

        var written: Int64 = 0
        for (index, segment) in parsed.segments.enumerated() {
            try Task.checkCancellation()
            let data: Data
            if index == 0 {
                data = firstSegmentData
                firstSegmentData = Data()
            } else {
                data = try await fetchSegment(
                    segment,
                    mediaSequence: parsed.mediaSequence,
                    index: index,
                    headers: headers,
                    keyCache: &keyCache,
                    nextOffsetByURL: &nextOffsetByURL
                )
            }
            if container == .mpegTransportStream {
                guard Self.looksLikeMPEGTS(data) else {
                    throw HLSExportError.containerChanged
                }
            } else if container == .adtsAAC {
                guard Self.looksLikeADTS(data) else {
                    throw HLSExportError.containerChanged
                }
            } else if container == .mp3 {
                guard Self.looksLikeMP3(data) else {
                    throw HLSExportError.containerChanged
                }
            }
            written += Int64(data.count)
            guard written <= Self.maximumStitchedSize,
                  written <= fileSizeLimit else {
                throw HLSExportError.fileTooLarge
            }
            try handle.write(contentsOf: data)
            await progress?(
                .downloadingSegments(
                    completed: index + 1,
                    total: totalSegments
                )
            )
        }
        try handle.synchronize()
        try handle.close()

        try Task.checkCancellation()
        await progress?(.convertingToM4A)

        // Stitched MPEG-TS with discontinuities often fails AVAssetReader with
        // AVError.fileFailedToParse (-11828 / HLS-SOURCE-11828). Demux to a
        // raw ADTS/MP3 elementary stream first — that opens reliably.
        //
        // Important: never `Data(contentsOf:)` the full stitch into a heap
        // buffer here — stitches can be up to `maximumStitchedSize` and that
        // allocation jetsams the app during Share on device.
        let transcodeURL: URL
        if container == .mpegTransportStream,
           let demuxed = try? MPEGTSAudioExtractor.extractAudioFile(
            from: sourceURL,
            toDirectory: stagingDirectory
           ) {
            let elementarySize = (try? demuxed.url
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            logger.info(
                "HLS export: demuxed MPEG-TS to \(demuxed.kind.fileExtension, privacy: .public), \(elementarySize) bytes"
            )
            transcodeURL = demuxed.url
        } else {
            transcodeURL = sourceURL
        }

        do {
            try await transcodeToM4A(
                source: AVURLAsset(url: transcodeURL),
                destination: destination
            )
            try enforceSizeLimit(destination, limit: fileSizeLimit)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// Exports an offline `.movpkg` HLS bundle produced by
    /// `AVAssetDownloadTask` into an M4A file. The package is readable by
    /// AVFoundation (it is how offline playback works), so audio is simply
    /// transcoded to AAC — the well-trodden reverse-proxy-free approach.
    func exportMovpkgToM4A(
        packageURL: URL,
        destination: URL,
        fileSizeLimit: Int64,
        progress: TrackExportProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        await progress?(.convertingToM4A)
        do {
            let asset = AVURLAsset(url: packageURL)
            try await transcodeToM4A(source: asset, destination: destination)
            try enforceSizeLimit(destination, limit: fileSizeLimit)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - CMAF pipeline

    /// Writes a playable M4A from an HLS fragmented MP4 stream by parsing
    /// `moof`/`mdat` fragments directly and feeding the compressed AAC
    /// samples into an `AVAssetWriter`. This bypasses the "stitch boxes and
    /// hope AVAssetReader accepts them" path that triggers `-11800`/`-17913`.
    private func exportCMAFToM4A(
        initializationData: Data,
        firstInitialization: HLSInitializationSection?,
        firstSegmentData: Data,
        segments: [HLSSegment],
        mediaSequence: Int,
        headers: [String: String],
        destination: URL,
        fileSizeLimit: Int64,
        keyCache: inout [URL: Data],
        nextOffsetByURL: inout [URL: Int],
        progress: TrackExportProgressHandler?
    ) async throws {
        try Task.checkCancellation()
        let demuxer = CMAFAudioDemuxer()
        let initialization: CMAFAudioDemuxer.InitializationInfo
        do {
            initialization = try demuxer.parseInitialization(initializationData)
        } catch let error as CMAFAudioDemuxer.CMAFError {
            logger.info(
                "HLS CMAF export: init parse failed \(String(describing: error))"
            )
            throw HLSDiagnosticError(
                stage: .parsingInitialization,
                publicCode: "HLS-CMAF-INIT",
                underlyingDomain: "CMAF",
                underlyingCode: nil,
                safeDetail: String(describing: error)
            )
        }
        guard initialization.codec == .aac else {
            throw HLSDiagnosticError(
                stage: .parsingInitialization,
                publicCode: "HLS-CMAF-CODEC",
                underlyingDomain: "CMAF",
                underlyingCode: nil,
                safeDetail: initialization.codec.rawValue
            )
        }

        // Collect every fragment (the first one was already fetched for
        // container detection) and demux it without materializing a single
        // stitched MP4 in memory.
        var allSamples: [CMAFAudioDemuxer.CompressedSample] = []
        var nextDecodeTime: Int64? = nil
        let totalSegments = segments.count

        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            guard segment.initialization == firstInitialization else {
                throw HLSExportError.changingInitializationSection
            }
            let data: Data
            if index == 0 {
                data = firstSegmentData
            } else {
                data = try await fetchSegment(
                    segment,
                    mediaSequence: mediaSequence,
                    index: index,
                    headers: headers,
                    keyCache: &keyCache,
                    nextOffsetByURL: &nextOffsetByURL
                )
            }
            if let key = segment.key {
                let keyData = try await fetchKeyData(
                    key,
                    headers: headers,
                    cache: &keyCache
                )
                let decrypted = try decryptSegment(
                    data,
                    key: keyData,
                    iv: key.iv(mediaSequence + index)
                )
                guard Self.containsBox(
                    decrypted,
                    types: ["moof", "mdat"]
                ) else {
                    throw HLSExportError.decryptedFragmentInvalid(index: index)
                }
                let fragmentSamples: [CMAFAudioDemuxer.CompressedSample]
                do {
                    fragmentSamples = try demuxer.parseFragment(
                        decrypted,
                        initialization: initialization,
                        decodeTime: &nextDecodeTime
                    )
                } catch let error as CMAFAudioDemuxer.CMAFError {
                    logger.info(
                        "HLS CMAF export: fragment \(index) parse failed \(String(describing: error))"
                    )
                    throw HLSDiagnosticError(
                        stage: .parsingFragment,
                        publicCode: "HLS-CMAF-TRUN",
                        underlyingDomain: "CMAF",
                        underlyingCode: index,
                        safeDetail: String(describing: error)
                    )
                }
                allSamples.append(contentsOf: fragmentSamples)
            } else {
                let fragmentSamples: [CMAFAudioDemuxer.CompressedSample]
                do {
                    fragmentSamples = try demuxer.parseFragment(
                        data,
                        initialization: initialization,
                        decodeTime: &nextDecodeTime
                    )
                } catch let error as CMAFAudioDemuxer.CMAFError {
                    logger.info(
                        "HLS CMAF export: fragment \(index) parse failed \(String(describing: error))"
                    )
                    throw HLSDiagnosticError(
                        stage: .parsingFragment,
                        publicCode: "HLS-CMAF-TRUN",
                        underlyingDomain: "CMAF",
                        underlyingCode: index,
                        safeDetail: String(describing: error)
                    )
                }
                allSamples.append(contentsOf: fragmentSamples)
            }

            try Task.checkCancellation()
            let estimated = Int64(allSamples.reduce(0) { $0 + $1.data.count })
            guard estimated <= fileSizeLimit else {
                throw HLSExportError.fileTooLarge
            }
            await progress?(
                .downloadingSegments(
                    completed: index + 1,
                    total: totalSegments
                )
            )
        }
        guard !allSamples.isEmpty else {
            throw HLSExportError.noFragments
        }

        await progress?(.convertingToM4A)
        try await writeCompressedAACToM4A(
            samples: allSamples,
            initialization: initialization,
            destination: destination
        )
        try enforceSizeLimit(destination, limit: fileSizeLimit)
    }

    /// Feeds already-compressed AAC samples straight into an M4A container
    /// via `AVAssetWriter` in passthrough mode (no PCM decode → no quality
    /// loss and no `AVAssetReader` half-file problem).
    private func writeCompressedAACToM4A(
        samples: [CMAFAudioDemuxer.CompressedSample],
        initialization: CMAFAudioDemuxer.InitializationInfo,
        destination: URL
    ) async throws {
        try? fileManager.removeItem(at: destination)

        let timescale = CMTimeScale(initialization.timescale)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: initialization.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            // MPEG-4 Audio Object Type 2 = AAC Low Complexity.
            mFormatFlags: 2,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: initialization.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let magicCookie = initialization.elementaryStreamDescriptor else {
            throw HLSDiagnosticError(
                stage: .creatingWriter,
                publicCode: "HLS-WRITER-ESDS",
                underlyingDomain: "CoreMedia",
                underlyingCode: nil,
                safeDetail: nil
            )
        }
        var activeFormat: CMAudioFormatDescription?
        let creationStatus = magicCookie.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: nil,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: magicCookie.count,
                magicCookie: cookie.baseAddress,
                extensions: nil,
                formatDescriptionOut: &activeFormat
            )
        }
        guard creationStatus == noErr, let format = activeFormat else {
            throw HLSDiagnosticError(
                stage: .creatingWriter,
                publicCode: "HLS-WRITER-FORMAT",
                underlyingDomain: "CoreMedia",
                underlyingCode: Int(creationStatus),
                safeDetail: nil
            )
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(
                outputURL: destination,
                fileType: .m4a
            )
        } catch let error as NSError {
            logger.error(
                "stage=creatingWriter domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            throw HLSDiagnosticError(
                stage: .creatingWriter,
                publicCode: "HLS-WRITER-\(abs(error.code))",
                underlyingDomain: error.domain,
                underlyingCode: error.code,
                safeDetail: nil
            )
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: format
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw HLSExportError.writerCannotAddInput
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            let code = writer.error?._code
            logger.error(
                "stage=startingWriter code=\(code ?? -1)"
            )
            throw HLSDiagnosticError(
                stage: .startingWriter,
                publicCode: "HLS-WRITER-START-\(code.map { abs($0) } ?? -1)",
                underlyingDomain: "AVFoundation",
                underlyingCode: code,
                safeDetail: nil
            )
        }
        writer.startSession(atSourceTime: .zero)

        for (index, sample) in samples.enumerated() {
            try Task.checkCancellation()
            var blockBuffer: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: sample.data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: sample.data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard blockStatus == noErr, let blockBuffer else {
                throw HLSDiagnosticError(
                    stage: .appendingSample,
                    publicCode: "HLS-SAMPLE-BUFFER",
                    underlyingDomain: "CoreMedia",
                    underlyingCode: Int(blockStatus),
                    safeDetail: "sample #\(index)"
                )
            }
            let copyStatus = sample.data.withUnsafeBytes { bytes in
                guard let source = bytes.baseAddress else {
                    return kCMBlockBufferBadCustomBlockSourceErr
                }
                return CMBlockBufferReplaceDataBytes(
                    with: source,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: sample.data.count
                )
            }
            guard copyStatus == noErr else {
                throw HLSDiagnosticError(
                    stage: .appendingSample,
                    publicCode: "HLS-SAMPLE-COPY",
                    underlyingDomain: "CoreMedia",
                    underlyingCode: Int(copyStatus),
                    safeDetail: "sample #\(index)"
                )
            }
            var timingInfo = CMSampleTimingInfo(
                duration: CMTime(
                    value: sample.duration,
                    timescale: timescale
                ),
                presentationTimeStamp: CMTime(
                    value: sample.presentationTime,
                    timescale: timescale
                ),
                decodeTimeStamp: .invalid
            )
            var sampleSize = sample.data.count
            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreate(
                allocator: nil,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
            guard status == noErr, let sampleBuffer else {
                throw HLSDiagnosticError(
                    stage: .appendingSample,
                    publicCode: "HLS-SAMPLE-CREATE",
                    underlyingDomain: "CoreMedia",
                    underlyingCode: Int(status),
                    safeDetail: "sample #\(index)"
                )
            }
            guard writerInput.append(sampleBuffer) else {
                let code = writer.error?._code
                logger.error(
                    "stage=appendingSample sample=\(index) code=\(code ?? -1)"
                )
                throw HLSDiagnosticError(
                    stage: .appendingSample,
                    publicCode: "HLS-SAMPLE-APPEND-\(index)",
                    underlyingDomain: "AVFoundation",
                    underlyingCode: code,
                    safeDetail: nil
                )
            }
        }
        writerInput.markAsFinished()

        try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    let error = writer.error ?? HLSExportError.writerFinishFailed(code: nil)
                    continuation.resume(throwing: error)
                }
            }
        }
        guard writer.status == .completed else {
            let code = writer.error?._code
            logger.error("stage=finishingWriter code=\(code ?? -1)")
            throw HLSDiagnosticError(
                stage: .finishingWriter,
                publicCode: "HLS-WRITER-FINISH-\(code.map { abs($0) } ?? -1)",
                underlyingDomain: "AVFoundation",
                underlyingCode: code,
                safeDetail: nil
            )
        }
    }

    // MARK: - Models

    private enum HLSResourceKind: String, Sendable {
        case masterManifest
        case mediaManifest
        case initialization
        case encryptionKey
        case mediaSegment

        var exportErrorKind: HLSExportErrorResourceKind {
            switch self {
            case .masterManifest: return .masterManifest
            case .mediaManifest: return .mediaManifest
            case .initialization: return .initialization
            case .encryptionKey: return .encryptionKey
            case .mediaSegment: return .mediaSegment
            }
        }
    }

    private struct HLSByteRangeSpec: Equatable, Sendable {
        let length: Int
        let explicitOffset: Int?
    }

    private struct HLSInitializationSection: Equatable, Sendable {
        let url: URL
        let byteRangeSpec: HLSByteRangeSpec?
        let key: EncryptionKey?

        var cacheKey: InitializationCacheKey {
            InitializationCacheKey(
                url: url,
                lowerBound: byteRangeSpec?.explicitOffset,
                upperBound: byteRangeSpec.flatMap { spec in
                    spec.explicitOffset.map { $0 + spec.length }
                }
            )
        }
    }

    private struct HLSSegment: Sendable {
        let url: URL
        let byteRangeSpec: HLSByteRangeSpec?
        let key: EncryptionKey?
        let initialization: HLSInitializationSection?
        let startsDiscontinuity: Bool
    }

    private struct HLSMediaPlaylist: Sendable {
        let segments: [HLSSegment]
        let mediaSequence: Int
    }

    enum HLSContainerKind: String, Equatable, Sendable {
        case mpegTransportStream
        case fragmentedMP4
        case adtsAAC
        case mp3

        var stagingExtension: String {
            switch self {
            case .mpegTransportStream: return "ts"
            case .fragmentedMP4: return "mp4"
            case .adtsAAC: return "aac"
            case .mp3: return "mp3"
            }
        }
    }

    private struct HLSVariant {
        var url: URL
        let bandwidth: Int
        let codecs: [String]
        let audioGroupID: String?
    }

    private struct HLSAudioRendition {
        let groupID: String
        let name: String?
        let url: URL
        let isDefault: Bool
        let isAutoselect: Bool
    }

    private struct InitializationCacheKey: Hashable {
        let url: URL
        let lowerBound: Int?
        let upperBound: Int?
    }

    private struct EncryptionKey: Equatable, Sendable {
        let url: URL
        let explicitIV: Data?

        var hasExplicitIV: Bool {
            explicitIV != nil
        }

        func iv(_ segmentNumber: Int) -> Data {
            if let explicitIV {
                return explicitIV
            }
            // RFC 8216 §5.2: default IV is the media sequence as a
            // 128-bit big-endian integer (8 zero bytes + 8 sequence bytes).
            var iv = Data(repeating: 0, count: 16)
            var sequence = UInt64(segmentNumber)
            for byteIndex in stride(from: 15, through: 8, by: -1) {
                iv[byteIndex] = UInt8(sequence & 0xff)
                sequence >>= 8
            }
            return iv
        }
    }

    // MARK: - Manifest resolution

    private func resolveMediaPlaylist(
        from streamURL: URL,
        headers: [String: String]
    ) async throws -> (playlist: String, baseURL: URL) {
        let playlistData = try await fetchData(
            from: streamURL,
            kind: .masterManifest,
            headers: headers
        )
        guard let text = String(data: playlistData, encoding: .utf8),
              text.contains("#EXTM3U") else {
            throw HLSExportError.invalidPlaylist
        }
        let baseURL = streamURL.deletingLastPathComponent()

        let renditions = parseAudioRenditions(in: text, baseURL: baseURL)
        let variants = parseVariants(in: text, baseURL: baseURL)
        guard !variants.isEmpty || !renditions.isEmpty else {
            // Already a media playlist.
            return (text, baseURL)
        }

        let chosen = chooseAudioPlaylist(
            variants: variants,
            renditions: renditions
        )
        guard let chosen else {
            throw HLSExportError.noAudioVariant
        }
        logger.info(
            "HLS export: chosen variant \(chosen.lastPathComponent) on \(chosen.host ?? "unknown-host")"
        )

        let mediaData = try await fetchData(
            from: chosen,
            kind: .mediaManifest,
            headers: headers
        )
        guard let mediaText = String(data: mediaData, encoding: .utf8),
              mediaText.contains("#EXTM3U") else {
            throw HLSExportError.invalidPlaylist
        }
        return (
            mediaText,
            chosen.deletingLastPathComponent()
        )
    }

    private func parseVariants(
        in playlist: String,
        baseURL: URL
    ) -> [HLSVariant] {
        let lines = playlist.components(separatedBy: .newlines)
        var variants: [HLSVariant] = []
        var pending: HLSVariant?
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let attributes = parseAttributeList(
                    String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                )
                pending = HLSVariant(
                    url: URL(fileURLWithPath: "pending"),
                    bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
                    codecs: (attributes["CODECS"] ?? "")
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ) },
                    audioGroupID: attributes["AUDIO"]
                )
                continue
            }
            guard !line.hasPrefix("#"), !line.isEmpty else { continue }
            if var variant = pending {
                variant.url = resolvedURL(line, base: baseURL)
                variants.append(variant)
                pending = nil
            }
        }
        return variants
    }

    private func parseAudioRenditions(
        in playlist: String,
        baseURL: URL
    ) -> [HLSAudioRendition] {
        let lines = playlist.components(separatedBy: .newlines)
        var renditions: [HLSAudioRendition] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-MEDIA:") else { continue }
            let attributes = parseAttributeList(
                String(line.dropFirst("#EXT-X-MEDIA:".count))
            )
            guard attributes["TYPE"]?.uppercased() == "AUDIO",
                  let groupID = attributes["GROUP-ID"],
                  let uri = attributes["URI"] else {
                continue
            }
            renditions.append(HLSAudioRendition(
                groupID: groupID,
                name: attributes["NAME"],
                url: resolvedURL(uri, base: baseURL),
                isDefault: attributes["DEFAULT"] == "YES",
                isAutoselect: attributes["AUTOSELECT"] == "YES"
            ))
        }
        return renditions
    }

    /// Selection order: `DEFAULT=YES` rendition → `AUTOSELECT=YES`
    /// rendition → first URI in a group referenced by a variant → best
    /// audio-only variant (codec mp4a/aac/ac-3/ec-3/mp3 and no video codec).
    /// Video-only variants are never chosen.
    private func chooseAudioPlaylist(
        variants: [HLSVariant],
        renditions: [HLSAudioRendition]
    ) -> URL? {
        if let defaulted = renditions.first(where: { $0.isDefault }) {
            return defaulted.url
        }
        if let autoselected = renditions.first(where: { $0.isAutoselect }) {
            return autoselected.url
        }
        let referencedGroups = Set(
            variants.compactMap(\.audioGroupID)
        )
        if let groupID = renditions.map(\.groupID).first(
            where: { referencedGroups.contains($0) }
        ), let rendition = renditions.first(where: {
            $0.groupID == groupID
        }) {
            return rendition.url
        }
        let audioOnly = variants.filter { variant in
            let audioCodec = variant.codecs.contains {
                $0.hasPrefix("mp4a") || $0.hasPrefix("aac")
                    || $0.hasPrefix("ac-3") || $0.hasPrefix("ec-3")
                    || $0.hasPrefix("mp3")
            }
            let videoCodec = variant.codecs.contains {
                $0.hasPrefix("avc1") || $0.hasPrefix("hvc1")
                    || $0.hasPrefix("hev1") || $0.hasPrefix("vp9")
                    || $0.hasPrefix("av01")
            }
            return audioCodec && !videoCodec
        }
        return audioOnly
            .max(by: { $0.bandwidth < $1.bandwidth })?
            .url
    }

    // MARK: - Playlist parsing

    private func parseSegments(
        in playlist: String,
        baseURL: URL
    ) throws -> HLSMediaPlaylist {
        var segments: [HLSSegment] = []
        var mediaSequence = 0
        var currentKey: EncryptionKey?
        var pendingByteRange: HLSByteRangeSpec?
        var pendingInitialization: HLSInitializationSection?
        var startsDiscontinuity = false

        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence =
                    Int(line.replacingOccurrences(
                        of: "#EXT-X-MEDIA-SEQUENCE:",
                        with: ""
                    )) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                currentKey = try parseKey(
                    line,
                    baseURL: baseURL
                )
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = parseByteRangeSpec(line)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                pendingInitialization = try parseInitializationSection(
                    line,
                    baseURL: baseURL,
                    currentKey: currentKey
                )
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") {
                startsDiscontinuity = true
            } else if !line.hasPrefix("#"), !line.isEmpty {
                guard segments.count < segmentLimit else {
                    throw HLSExportError.tooManySegments
                }
                segments.append(HLSSegment(
                    url: resolvedURL(line, base: baseURL),
                    byteRangeSpec: pendingByteRange,
                    key: currentKey,
                    initialization: pendingInitialization,
                    startsDiscontinuity: startsDiscontinuity
                ))
                pendingByteRange = nil
                startsDiscontinuity = false
            }
        }
        return HLSMediaPlaylist(
            segments: segments,
            mediaSequence: mediaSequence
        )
    }

    /// Parses `#EXT-X-KEY`. `METHOD=NONE` clears the current key;
    /// `METHOD=AES-128` requires a URI and accepts an optional IV; any other
    /// method (SAMPLE-AES, ...) is rejected instead of being treated as
    /// clear content.
    private func parseKey(_ line: String, baseURL: URL) throws -> EncryptionKey? {
        let attributes = parseAttributeList(
            String(line.dropFirst("#EXT-X-KEY:".count))
        )
        guard let method = attributes["METHOD"] else {
            throw HLSExportError.invalidEncryptionKey
        }
        switch method.uppercased() {
        case "NONE":
            return nil
        case "AES-128":
            guard let uri = attributes["URI"] else {
                throw HLSExportError.invalidEncryptionKey
            }
            var explicitIV: Data?
            if let ivString = attributes["IV"] {
                var hex = ivString
                if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
                    hex = String(hex.dropFirst(2))
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
            return EncryptionKey(
                url: resolvedURL(uri, base: baseURL),
                explicitIV: explicitIV
            )
        default:
            throw HLSExportError.unsupportedEncryptionMethod(method)
        }
    }

    private func parseByteRangeSpec(_ line: String) -> HLSByteRangeSpec? {
        let value = line.replacingOccurrences(
            of: "#EXT-X-BYTERANGE:",
            with: ""
        )
        let parts = value.split(separator: "@")
        guard let length = Int(parts.first ?? "") else { return nil }
        let explicitOffset = parts.count > 1
            ? Int(parts[1])
            : nil
        return HLSByteRangeSpec(
            length: length,
            explicitOffset: explicitOffset
        )
    }

    /// Parses `#EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"`. The map keeps a
    /// snapshot of the current key; an AES-128-encrypted map must carry an
    /// explicit IV (the media-sequence default does not apply to maps).
    private func parseInitializationSection(
        _ line: String,
        baseURL: URL,
        currentKey: EncryptionKey?
    ) throws -> HLSInitializationSection {
        let attributes = parseAttributeList(
            String(line.dropFirst("#EXT-X-MAP:".count))
        )
        guard let uri = attributes["URI"] else {
            throw HLSExportError.invalidInitializationSection
        }
        let byteRangeSpec: HLSByteRangeSpec?
        if let rawRange = attributes["BYTERANGE"] {
            let parts = rawRange.split(separator: "@")
            guard let length = Int(parts.first ?? "") else {
                throw HLSExportError.invalidByteRange
            }
            let explicitOffset = parts.count > 1
                ? Int(parts[1])
                : nil
            byteRangeSpec = HLSByteRangeSpec(
                length: length,
                explicitOffset: explicitOffset
            )
        } else {
            byteRangeSpec = nil
        }
        if let key = currentKey, !key.hasExplicitIV {
            throw HLSExportError.encryptedInitializationRequiresExplicitIV
        }
        return HLSInitializationSection(
            url: resolvedURL(uri, base: baseURL),
            byteRangeSpec: byteRangeSpec,
            key: currentKey
        )
    }

    /// Quote-aware attribute list parser: quoted values may contain commas.
    private func parseAttributeList(
        _ rawValue: String
    ) -> [String: String] {
        var result: [String: String] = [:]
        var tokens: [String] = []
        var token = ""
        var isInsideQuotes = false

        for character in rawValue {
            if character == "\"" {
                isInsideQuotes.toggle()
                token.append(character)
            } else if character == ",", !isInsideQuotes {
                tokens.append(token)
                token = ""
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty {
            tokens.append(token)
        }

        for token in tokens {
            guard let equals = token.firstIndex(of: "=") else {
                continue
            }
            let key = String(token[..<equals])
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            var value = String(token[token.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""),
               value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    /// Resolves a BYTERANGE spec. An implicit offset continues the previous
    /// range of the *same URL*; each URL keeps its own offset.
    private func resolveByteRange(
        _ spec: HLSByteRangeSpec?,
        for url: URL,
        nextOffsetByURL: inout [URL: Int]
    ) throws -> Range<Int>? {
        guard let spec else { return nil }
        guard spec.length > 0 else {
            throw HLSExportError.invalidByteRange
        }

        let start = spec.explicitOffset
            ?? nextOffsetByURL[url]
            ?? 0
        guard start >= 0,
              start <= Int.max - spec.length else {
            throw HLSExportError.invalidByteRange
        }

        let end = start + spec.length
        nextOffsetByURL[url] = end
        return start..<end
    }

    private func resolvedURL(_ string: String, base: URL) -> URL {
        if let absolute = URL(string: string), absolute.scheme != nil {
            return absolute
        }
        // URL(string:relativeTo:) resolves per RFC 3986, handling ../
        // and other relative components that appendPathComponent breaks.
        return URL(string: string, relativeTo: base)
            ?? base.appendingPathComponent(string)
    }

    // MARK: - Segment fetching

    private func fetchInitialization(
        _ initialization: HLSInitializationSection,
        headers: [String: String],
        keyCache: inout [URL: Data],
        cache: inout [InitializationCacheKey: Data],
        nextOffsetByURL: inout [URL: Int]
    ) async throws -> Data {
        if let cached = cache[initialization.cacheKey] {
            return cached
        }
        let range = try resolveByteRange(
            initialization.byteRangeSpec,
            for: initialization.url,
            nextOffsetByURL: &nextOffsetByURL
        )
        var data = try await fetchData(
            from: initialization.url,
            kind: .initialization,
            headers: headers,
            byteRange: range
        )
        if let key = initialization.key {
            let keyData = try await fetchKeyData(
                key,
                headers: headers,
                cache: &keyCache
            )
            // Explicit IV is enforced by parseInitializationSection.
            data = try decryptSegment(
                data,
                key: keyData,
                iv: key.iv(0)
            )
            guard Self.containsBox(data, types: ["ftyp", "moov"]) else {
                throw HLSExportError.decryptedInitializationInvalid
            }
        }
        cache[initialization.cacheKey] = data
        return data
    }

    private func fetchSegment(
        _ segment: HLSSegment,
        mediaSequence: Int,
        index: Int,
        headers: [String: String],
        keyCache: inout [URL: Data],
        nextOffsetByURL: inout [URL: Int]
    ) async throws -> Data {
        let range = try resolveByteRange(
            segment.byteRangeSpec,
            for: segment.url,
            nextOffsetByURL: &nextOffsetByURL
        )
        var data = try await fetchData(
            from: segment.url,
            kind: .mediaSegment,
            headers: headers,
            byteRange: range
        )
        if let key = segment.key {
            let keyData = try await fetchKeyData(
                key,
                headers: headers,
                cache: &keyCache
            )
            data = try decryptSegment(
                data,
                key: keyData,
                iv: key.iv(mediaSequence + index)
            )
        }
        return data
    }

    private func fetchKeyData(
        _ key: EncryptionKey,
        headers: [String: String],
        cache: inout [URL: Data]
    ) async throws -> Data {
        if let cached = cache[key.url] {
            return cached
        }
        let data = try await fetchData(
            from: key.url,
            kind: .encryptionKey,
            headers: headers
        )
        cache[key.url] = data
        return data
    }

    private func fetchData(
        from url: URL,
        kind: HLSResourceKind,
        headers: [String: String],
        byteRange: Range<Int>? = nil,
        retries: Int = 1
    ) async throws -> Data {
        var lastError: Error?
        for attempt in 0...retries {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
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
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.info(
                    "HLS fetch \(kind.rawValue): http \(code), host \(self.safeHost(url)), ext \(url.pathExtension)"
                )
                lastError = HLSExportError.httpFailure(
                    kind: kind.exportErrorKind,
                    status: code
                )
                if attempt < retries {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                throw lastError!
            }
            logger.info(
                "HLS fetch \(kind.rawValue): \(data.count) bytes, host \(self.safeHost(url)), ext \(url.pathExtension), mime \(http.mimeType ?? "unknown"), magic \(Self.magicPrefix(data))"
            )
            guard !data.isEmpty else {
                lastError = HLSExportError.emptyResponse(kind: kind.exportErrorKind)
                if attempt < retries {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                throw lastError!
            }
            let validatedData: Data
            if let byteRange {
                validatedData = try validateRangeResponse(
                    data,
                    http: http,
                    expectedRange: byteRange
                )
            } else {
                validatedData = data
            }
            return validatedData
        }
        throw lastError ?? HLSExportError.network
    }

    // MARK: - Container detection

    /// Detects the real segment container. `EXT-X-MAP` implies fMP4/CMAF and
    /// is validated against ISO BMFF boxes; otherwise the first segment's
    /// magic bytes decide between MPEG-TS, ADTS AAC, MP3 and an unsupported
    /// container.
    static func detectContainer(
        initializationData: Data?,
        firstSegmentData: Data
    ) throws -> HLSContainerKind {
        if let initializationData {
            guard containsBox(initializationData, types: ["ftyp", "moov"])
            else {
                throw HLSExportError.invalidInitializationSection
            }
            guard containsBox(firstSegmentData, types: ["moof", "mdat"])
                || containsBox(
                    firstSegmentData,
                    types: ["styp", "moof", "mdat"]
                ) else {
                throw HLSExportError.unsupportedSegmentContainer
            }
            return .fragmentedMP4
        }
        if looksLikeMPEGTS(firstSegmentData) {
            return .mpegTransportStream
        }
        if looksLikeADTS(firstSegmentData) {
            return .adtsAAC
        }
        if looksLikeMP3(firstSegmentData) {
            return .mp3
        }
        throw HLSExportError.unsupportedSegmentContainer
    }

    /// Bounded ISO BMFF box walker: handles 32-bit sizes, extended 64-bit
    /// sizes and a zero size (box runs to the end of the data).
    static func containsBox(_ data: Data, types: [String]) -> Bool {
        var found = Set(types)
        var offset = 0
        let count = data.count
        while offset + 8 <= count {
            let size32 = data.withUnsafeBytes { raw in
                raw.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                ).bigEndian
            }
            let type = String(
                data: data.subdata(
                    in: offset + 4..<offset + 8
                ),
                encoding: .ascii
            ) ?? ""
            let boxSize: Int
            if size32 == 1 {
                guard offset + 16 <= count else { break }
                let size64 = data.withUnsafeBytes { raw in
                    raw.loadUnaligned(
                        fromByteOffset: offset + 8,
                        as: UInt64.self
                    ).bigEndian
                }
                boxSize = size64 > Int.max ? count - offset : Int(size64)
            } else if size32 == 0 {
                boxSize = count - offset
            } else {
                boxSize = Int(size32)
            }
            if found.contains(type) {
                found.remove(type)
            }
            guard boxSize >= 8 else { break }
            offset += boxSize
            if found.isEmpty {
                return true
            }
        }
        return found.isEmpty
    }

    static func looksLikeMPEGTS(_ data: Data) -> Bool {
        let packetSizes = [188, 192, 204]
        for initialOffset in 0..<min(16, data.count) {
            guard data[initialOffset] == 0x47 else { continue }
            // A short BYTERANGE peek may contain fewer than two full packets;
            // a leading sync byte is still enough to classify the container.
            let hasSecondSync = packetSizes.contains { packetSize in
                let second = initialOffset + packetSize
                return second < data.count && data[second] == 0x47
            }
            if hasSecondSync || data.count <= packetSizes[0] {
                return true
            }
        }
        return false
    }

    static func looksLikeADTS(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == 0xFF
            && data[1] & 0xF6 == 0xF0
    }

    static func looksLikeMP3(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        if data.count >= 3,
           data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 {
            return true
        }
        guard data[0] == 0xFF else { return false }
        let versionBits = (data[1] >> 3) & 0x03
        let layerBits = (data[1] >> 1) & 0x03
        guard versionBits != 1, layerBits != 0 else { return false }
        return data[1] & 0xE0 == 0xE0
    }

    // MARK: - Logging helpers

    private func safeHost(_ url: URL) -> String {
        url.host ?? "unknown-host"
    }

    private static func magicPrefix(_ data: Data) -> String {
        data.prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Crypto (AES-128 CBC per RFC 8216)

    /// Validates a BYTERANGE response body: a 206 must be exactly the
    /// requested length; a 200 (full resource) is sliced locally — some CDNs
    /// ignore Range headers and RCF 9110 still allows it.
    private func validateRangeResponse(
        _ data: Data,
        http: HTTPURLResponse,
        expectedRange: Range<Int>
    ) throws -> Data {
        let expectedLength = expectedRange.count
        if http.statusCode == 206 {
            guard data.count == expectedLength else {
                throw HLSExportError.invalidRangeResponse(
                    expectedLength: expectedLength,
                    actualLength: data.count,
                    status: 206
                )
            }
            return data
        }
        // 200 means the CDN ignored the Range header: slice the requested
        // bytes out of the full resource.
        guard data.count > expectedRange.lowerBound,
              data.count >= expectedRange.upperBound else {
            throw HLSExportError.invalidRangeResponse(
                expectedLength: expectedLength,
                actualLength: data.count,
                status: http.statusCode
            )
        }
        return data.subdata(in: expectedRange)
    }

    private func decryptSegment(
        _ data: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw HLSExportError.decryptionFailed
        }
        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
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
                            outputCapacity,
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

    // MARK: - Size limit

    private func enforceSizeLimit(_ url: URL, limit: Int64) throws {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let size, Int64(size) > limit {
            throw HLSExportError.fileTooLarge
        }
    }

    /// Reads sample rate / channel count via the typed async property so we
    /// never force-cast opaque `formatDescriptions` boxes.
    private static func audioStreamBasicDescription(
        from track: AVAssetTrack
    ) async -> AudioStreamBasicDescription? {
        let descriptions: [CMFormatDescription]
        do {
            descriptions = try await track.load(.formatDescriptions)
        } catch {
            return nil
        }
        for formatDescription in descriptions {
            guard let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
            ) else {
                continue
            }
            return pointer.pointee
        }
        return nil
    }

    /// Loads audio tracks with one retry. Media-services contention (active
    /// playback) and freshly written files sometimes fail the first
    /// `loadTracks` with `AVError.fileFailedToParse` (-11828).
    private func loadAudioTracks(
        from source: AVURLAsset
    ) async throws -> [AVAssetTrack] {
        var lastError: Error?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            do {
                _ = try await source.load(.isPlayable, .duration)
                let tracks = try await source.loadTracks(withMediaType: .audio)
                if !tracks.isEmpty {
                    return tracks
                }
                // Empty tracks are not a parse failure — let the caller map
                // that to `noAudioTrack` without inventing a SOURCE code.
                return []
            } catch {
                lastError = error
                logger.error(
                    "stage=openingLinearSource attempt=\(attempt) error=\(String(describing: error), privacy: .public)"
                )
            }
            if attempt == 0 {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        if let lastError { throw lastError }
        return []
    }

    // MARK: - Transcode (any AVFoundation asset) → AAC M4A

    /// Universal path: decode the source to linear PCM with AVAssetReader
    /// and encode to AAC-in-MP4 with AVAssetWriter. Works for stitched
    /// MPEG-TS, fragmented MP4, ADTS AAC, MP3, offline `.movpkg` bundles,
    /// regardless of whether the source codec is AAC/MP3/AC-3 — unlike a
    /// copy-remux, which AVAssetWriter refuses for TS ADTS frames.
    ///
    /// Equivalent of `ffmpeg -i input -c:a aac -b:a 192k out.m4a`, but
    /// with the hardware-accelerated iOS AAC encoder.
    private func transcodeToM4A(
        source: AVURLAsset,
        destination: URL
    ) async throws {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await loadAudioTracks(from: source)
        } catch let error as HLSDiagnosticError {
            throw error
        } catch let error as NSError {
            logger.error(
                "stage=openingLinearSource domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            throw HLSDiagnosticError(
                stage: .openingLinearSource,
                publicCode: "HLS-SOURCE-\(abs(error.code))",
                underlyingDomain: error.domain,
                underlyingCode: error.code,
                safeDetail: nil
            )
        }
        guard let track = tracks.first else {
            logger.info("HLS transcode: no audio track in source")
            throw HLSExportError.noAudioTrack
        }

        let asbd = await Self.audioStreamBasicDescription(from: track)
        let sampleRate = asbd?.mSampleRate ?? 44100
        let sourceChannels = UInt32(asbd?.mChannelsPerFrame ?? 2)
        let channels: UInt32 = min(2, max(1, sourceChannels))

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw HLSExportError.noAudioTrack
        }
        let readerSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: pcmFormat.sampleRate,
            AVNumberOfChannelsKey: Int(pcmFormat.channelCount),
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source)
        } catch let error as NSError {
            logger.error(
                "stage=creatingReader domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            throw HLSDiagnosticError(
                stage: .creatingReader,
                publicCode: "HLS-READER-\(abs(error.code))",
                underlyingDomain: error.domain,
                underlyingCode: error.code,
                safeDetail: nil
            )
        }
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: readerSettings
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            logger.info("HLS transcode: reader cannot add output")
            throw HLSExportError.readerCannotAddOutput
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(
            outputURL: destination,
            fileType: .m4a
        )
        let bitRate = Int(min(192_000, max(96_000,
            sampleRate * Double(channels) * 2)))
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: Int(pcmFormat.sampleRate),
                AVNumberOfChannelsKey: Int(pcmFormat.channelCount),
                AVEncoderBitRateKey: bitRate,
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            logger.info("HLS transcode: writer cannot add input")
            throw HLSExportError.writerCannotAddInput
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            let code = reader.error?._code
            logger.error(
                "stage=startingReader code=\(code ?? -1)"
            )
            throw HLSDiagnosticError(
                stage: .startingReader,
                publicCode: "HLS-READER-START-\(code.map { abs($0) } ?? -1)",
                underlyingDomain: "AVFoundation",
                underlyingCode: code,
                safeDetail: nil
            )
        }
        guard writer.startWriting() else {
            let code = writer.error?._code
            logger.error(
                "stage=startingWriter code=\(code ?? -1)"
            )
            throw HLSDiagnosticError(
                stage: .startingWriter,
                publicCode: "HLS-WRITER-START-\(code.map { abs($0) } ?? -1)",
                underlyingDomain: "AVFoundation",
                underlyingCode: code,
                safeDetail: nil
            )
        }
        writer.startSession(atSourceTime: .zero)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "PrivateMusic.HLSTranscode")
                let stateLock = NSLock()
                var didFinish = false
                let finishOnce: (Result<Void, Error>) -> Void = { result in
                    stateLock.lock()
                    let shouldResume = !didFinish
                    didFinish = true
                    stateLock.unlock()
                    guard shouldResume else { return }
                    switch result {
                    case .success:
                        continuation.resume(returning: ())
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        if Task.isCancelled {
                            writerInput.markAsFinished()
                            writer.cancelWriting()
                            reader.cancelReading()
                            finishOnce(.failure(CancellationError()))
                            return
                        }
                        if let sample = readerOutput.copyNextSampleBuffer() {
                            if !writerInput.append(sample) {
                                writerInput.markAsFinished()
                                writer.cancelWriting()
                                reader.cancelReading()
                                finishOnce(.failure(
                                    writer.error.map {
                                        HLSExportError.writerAppendFailed(
                                            code: $0._code
                                        )
                                    } ?? HLSExportError.noAudioTrack
                                ))
                                return
                            }
                        } else {
                            writerInput.markAsFinished()
                            if let readerError = reader.error {
                                writer.cancelWriting()
                                finishOnce(.failure(readerError))
                                return
                            }
                            writer.finishWriting {
                                if writer.status == .completed {
                                    finishOnce(.success(()))
                                } else {
                                    finishOnce(.failure(
                                        writer.error.map {
                                            HLSExportError.writerFinishFailed(
                                                code: $0._code
                                            )
                                        } ?? HLSExportError.noAudioTrack
                                    ))
                                }
                            }
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
    case httpFailure(kind: HLSExportErrorResourceKind, status: Int)
    case emptyResponse(kind: HLSExportErrorResourceKind)
    case cannotCreateStagingFile
    case fileTooLarge
    case decryptionFailed
    case unsupportedEncryptionMethod(String)
    case invalidEncryptionKey
    case encryptedInitializationRequiresExplicitIV
    case invalidInitializationSection
    case missingInitializationSection
    case changingInitializationSection
    case unsupportedSegmentContainer
    case containerChanged
    case noAudioVariant
    case invalidByteRange
    case noFragments
    case noAudioTrack
    case readerCannotAddOutput
    case readerStartFailed(code: Int?)
    case writerCannotAddInput
    case writerStartFailed(code: Int?)
    case writerAppendFailed(code: Int?)
    case writerFinishFailed(code: Int?)
    case invalidRangeResponse(
        expectedLength: Int,
        actualLength: Int,
        status: Int
    )
    case decryptedInitializationInvalid
    case decryptedFragmentInvalid(index: Int)

    var errorDescription: String? {
        switch self {
        case .invalidPlaylist, .emptyPlaylist, .tooManySegments,
             .noAudioVariant, .unsupportedEncryptionMethod,
             .invalidEncryptionKey:
            return L10n.text("VK вернул неподдерживаемый аудиопоток.")
        case .network, .httpFailure, .emptyResponse:
            return L10n.text("Не удалось скачать аудиопоток.")
        case .decryptionFailed, .encryptedInitializationRequiresExplicitIV:
            return L10n.text("Не удалось расшифровать аудиопоток.")
        case .cannotCreateStagingFile:
            return L10n.text("Не удалось создать временный файл.")
        case .fileTooLarge:
            return L10n.text("Файл больше 150 МБ.")
        case .invalidInitializationSection,
             .missingInitializationSection,
             .changingInitializationSection,
             .unsupportedSegmentContainer,
             .containerChanged,
             .invalidByteRange,
             .noFragments, .noAudioTrack,
             .readerCannotAddOutput, .readerStartFailed,
             .writerCannotAddInput, .writerStartFailed,
             .writerAppendFailed, .writerFinishFailed,
             .invalidRangeResponse,
             .decryptedInitializationInvalid, .decryptedFragmentInvalid:
            return L10n.text("Не удалось собрать аудиопоток.")
        }
    }
}

/// Plain mirror of the exporter's resource kinds so errors can stay
/// Sendable and testable without exposing the private enum.
enum HLSExportErrorResourceKind: String, Sendable {
    case masterManifest
    case mediaManifest
    case initialization
    case encryptionKey
    case mediaSegment
}

/// Stage where the HLS → M4A export failed. Downstream error presentation
/// maps these to safe user-visible messages.
enum HLSFailureStage: String, Sendable {
    case resolvingManifest
    case parsingManifest
    case downloadingInitialization
    case downloadingSegment
    case decrypting
    case parsingInitialization
    case parsingFragment
    case assemblingLinearSource
    case openingLinearSource
    case creatingReader
    case startingReader
    case creatingWriter
    case startingWriter
    case appendingSample
    case finishingWriter
    case validatingOutput
}

/// Diagnostic error that never leaks the underlying AVFoundation error
/// string to the UI. `publicCode` is the safe value shown via "Copy error
/// code"; the numeric fields stay in logs.
struct HLSDiagnosticError: LocalizedError, Sendable {
    let stage: HLSFailureStage
    let publicCode: String
    let underlyingDomain: String?
    let underlyingCode: Int?
    let safeDetail: String?

    var errorDescription: String? {
        switch stage {
        case .resolvingManifest,
             .downloadingInitialization,
             .downloadingSegment:
            return L10n.text("Не удалось скачать аудиопоток.")
        case .decrypting:
            return L10n.text("Не удалось расшифровать аудиопоток.")
        case .openingLinearSource,
             .creatingReader,
             .startingReader,
             .validatingOutput:
            if publicCode == "HLS-SOURCE-11828" {
                return L10n.text(
                    "Не удалось разобрать собранный аудиопоток. "
                        + "Попробуйте ещё раз или выберите другой трек."
                )
            }
            return L10n.text("Не удалось открыть собранный аудиопоток.")
        default:
            return L10n.text("Не удалось создать аудиофайл из этого потока.")
        }
    }
}
