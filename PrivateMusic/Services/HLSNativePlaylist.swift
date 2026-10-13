import Foundation

/// Swift face of the Rust playlist parser (`native/pm-native/src/hls.rs`).
/// Rust returns byte offsets into the playlist text; this type turns them
/// into plain values. URL resolution stays with Foundation in the exporter.
enum HLSNativePlaylist {
    struct ByteRange {
        let length: Int
        let offset: Int?
    }

    struct Key {
        let uri: String
        let iv: Data?
    }

    struct Map {
        let uri: String
        let range: ByteRange?
        /// Index into `Media.keys`, or -1.
        let keyIndex: Int
    }

    struct Segment {
        let uri: String
        let range: ByteRange?
        let keyIndex: Int
        let mapIndex: Int
        let startsDiscontinuity: Bool
    }

    struct Media {
        let mediaSequence: Int
        let keys: [Key]
        let maps: [Map]
        let segments: [Segment]
    }

    enum Choice {
        case mediaPlaylist
        case uri(String)
        case none
    }

    enum Failure: Error {
        case invalidText
        case invalidEncryptionKey
        case unsupportedEncryptionMethod(String)
        case invalidInitializationSection
        case invalidByteRange
        case encryptedInitializationRequiresExplicitIV
        case tooManySegments

        var exportError: HLSExportError {
            switch self {
            case .invalidText: return .invalidPlaylist
            case .invalidEncryptionKey: return .invalidEncryptionKey
            case .unsupportedEncryptionMethod(let method):
                return .unsupportedEncryptionMethod(method)
            case .invalidInitializationSection: return .invalidInitializationSection
            case .invalidByteRange: return .invalidByteRange
            case .encryptedInitializationRequiresExplicitIV:
                return .encryptedInitializationRequiresExplicitIV
            case .tooManySegments: return .tooManySegments
            }
        }
    }

    /// Picks the audio playlist out of a master playlist.
    static func chooseAudio(in playlist: String) throws -> Choice {
        let utf8 = Array(playlist.utf8)
        var uri = pm_hls_slice(offset: 0, length: -1)
        let code = utf8.withUnsafeBufferPointer { text in
            pm_hls_choose_audio(text.baseAddress, Int32(clamping: text.count), &uri)
        }
        switch code {
        case Int32(PM_HLS_CHOOSE_MEDIA_PLAYLIST): return .mediaPlaylist
        case Int32(PM_HLS_CHOOSE_FOUND): return .uri(string(uri, in: utf8))
        case Int32(PM_HLS_CHOOSE_NONE): return .none
        default: throw Failure.invalidText
        }
    }

    /// Parses a media playlist into segments with their key, map and range.
    static func parse(_ playlist: String, segmentLimit: Int) throws -> Media {
        let utf8 = Array(playlist.utf8)
        let limit = Int32(clamping: segmentLimit)
        var info = pm_hls_media_info()
        // First pass sizes the tables; the code is final either way.
        _ = utf8.withUnsafeBufferPointer { text in
            pm_hls_parse_media(
                text.baseAddress, Int32(clamping: text.count), limit,
                &info, nil, 0, nil, 0, nil, 0
            )
        }
        try check(info, in: utf8)

        var segments = [pm_hls_segment](repeating: pm_hls_segment(), count: Int(info.segment_count))
        var keys = [pm_hls_key](repeating: pm_hls_key(), count: Int(info.key_count))
        var maps = [pm_hls_map](repeating: pm_hls_map(), count: Int(info.map_count))
        _ = utf8.withUnsafeBufferPointer { text in
            segments.withUnsafeMutableBufferPointer { segmentTable in
                keys.withUnsafeMutableBufferPointer { keyTable in
                    maps.withUnsafeMutableBufferPointer { mapTable in
                        pm_hls_parse_media(
                            text.baseAddress, Int32(clamping: text.count), limit, &info,
                            segmentTable.baseAddress, Int32(clamping: segmentTable.count),
                            keyTable.baseAddress, Int32(clamping: keyTable.count),
                            mapTable.baseAddress, Int32(clamping: mapTable.count)
                        )
                    }
                }
            }
        }

        return Media(
            mediaSequence: Int(info.media_sequence),
            keys: keys.map { key in
                var iv: Data?
                if key.has_iv {
                    iv = withUnsafeBytes(of: key.iv) { Data($0) }
                }
                return Key(uri: string(key.uri, in: utf8), iv: iv)
            },
            maps: maps.map { map in
                Map(
                    uri: string(map.uri, in: utf8),
                    range: map.has_range
                        ? ByteRange(
                            length: Int(map.range_length),
                            offset: map.has_range_offset ? Int(map.range_offset) : nil
                        )
                        : nil,
                    keyIndex: Int(map.key_index)
                )
            },
            segments: segments.map { segment in
                Segment(
                    uri: string(segment.uri, in: utf8),
                    range: segment.has_range
                        ? ByteRange(
                            length: Int(segment.range_length),
                            offset: segment.has_range_offset ? Int(segment.range_offset) : nil
                        )
                        : nil,
                    keyIndex: Int(segment.key_index),
                    mapIndex: Int(segment.map_index),
                    startsDiscontinuity: segment.discontinuity
                )
            }
        )
    }

    private static func check(_ info: pm_hls_media_info, in utf8: [UInt8]) throws {
        switch info.code {
        case Int32(PM_HLS_OK): return
        case Int32(PM_HLS_INVALID_ENCRYPTION_KEY): throw Failure.invalidEncryptionKey
        case Int32(PM_HLS_UNSUPPORTED_ENCRYPTION_METHOD):
            throw Failure.unsupportedEncryptionMethod(string(info.detail, in: utf8))
        case Int32(PM_HLS_INVALID_INITIALIZATION_SECTION):
            throw Failure.invalidInitializationSection
        case Int32(PM_HLS_INVALID_BYTE_RANGE): throw Failure.invalidByteRange
        case Int32(PM_HLS_ENCRYPTED_INIT_NEEDS_IV):
            throw Failure.encryptedInitializationRequiresExplicitIV
        case Int32(PM_HLS_TOO_MANY_SEGMENTS): throw Failure.tooManySegments
        default: throw Failure.invalidText
        }
    }

    private static func string(_ slice: pm_hls_slice, in utf8: [UInt8]) -> String {
        guard slice.length >= 0 else { return "" }
        let start = Int(slice.offset)
        let end = start + Int(slice.length)
        guard start >= 0, end <= utf8.count else { return "" }
        return String(decoding: utf8[start..<end], as: UTF8.self)
    }
}
