import Foundation

/// Safe ISO/IEC 14496-12 (ISO Base Media File Format) box parser.
///
/// Parses box structure without depending on `Data.range(of:)`, which can
/// mis-detect FourCC strings inside binary payloads. Supports 32-bit box
/// sizes, `size == 1` (extended 64-bit size) and `size == 0` (box runs to
/// the end of the parent). Nested container bodies are walked iteratively
/// with explicit bounds checking, so a malformed fragment cannot trigger
/// out-of-bounds reads or integer overflows.
struct ISOBoxReader {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    struct ISOBox: Equatable, Sendable {
        /// Four-character code (e.g. "ftyp", "moov", "trak", "mp4a").
        let type: String
        /// Full range of the box header + payload inside the parent buffer.
        let range: Range<Int>
        /// Bytes consumed by the box header itself (8, 16 or 24 for uuid).
        let headerSize: Int

        var payloadRange: Range<Int> {
            (range.lowerBound + headerSize)..<range.upperBound
        }
    }

    // MARK: - Public API

    /// Iterates through every top-level box in the data.
    func boxes() throws -> [ISOBox] {
        try walk(from: 0, to: data.count)
    }

    /// Iterates through the payload of a container box (e.g. `moov`,
    /// `trak`, `minf`, `stbl`, `mvex`, `moof`, `traf`).
    func children(of box: ISOBox) throws -> [ISOBox] {
        try children(of: box, skipping: 0)
    }

    /// Iterates through a container after a fixed non-box prefix. Full boxes
    /// such as `stsd` begin with version/flags and entry count; sample entries
    /// contain a fixed audio header before their nested codec boxes.
    func children(
        of box: ISOBox,
        skipping prefixByteCount: Int
    ) throws -> [ISOBox] {
        guard prefixByteCount >= 0 else {
            throw ISOBoxReaderError.invalidBox("negative child prefix")
        }
        return try walk(
            from: box.range.lowerBound + box.headerSize + prefixByteCount,
            to: box.range.upperBound
        )
    }

    /// Returns the first direct child with the given four-character code
    /// or nil if there is none.
    func child(_ type: String, in box: ISOBox) throws -> ISOBox? {
        try child(type, in: box, skipping: 0)
    }

    func child(
        _ type: String,
        in box: ISOBox,
        skipping prefixByteCount: Int
    ) throws -> ISOBox? {
        try children(of: box, skipping: prefixByteCount)
            .first(where: { $0.type == type })
    }

    // MARK: - Typed big-endian payload readers

    func readUInt8(at offset: Int) throws -> UInt8 {
        try require(offset: offset, byteCount: 1)
        return data[offset]
    }

    func readUInt16BE(at offset: Int) throws -> UInt16 {
        try require(offset: offset, byteCount: 2)
        return data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                .bigEndian
        }
    }

    func readUInt24BE(at offset: Int) throws -> UInt32 {
        try require(offset: offset, byteCount: 3)
        var value: UInt32 = 0
        for byte in offset..<(offset + 3) {
            value = (value << 8) | UInt32(data[byte])
        }
        return value
    }

    func readUInt32BE(at offset: Int) throws -> UInt32 {
        try require(offset: offset, byteCount: 4)
        return data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                .bigEndian
        }
    }

    func readInt32BE(at offset: Int) throws -> Int32 {
        Int32(bitPattern: try readUInt32BE(at: offset))
    }

    func readUInt64BE(at offset: Int) throws -> UInt64 {
        try require(offset: offset, byteCount: 8)
        return data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                .bigEndian
        }
    }

    func readBytes(at range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0,
              range.lowerBound <= range.upperBound,
              range.upperBound <= data.count else {
            throw ISOBoxReaderError.truncated(
                expected: range.count,
                available: max(0, data.count - max(range.lowerBound, 0))
            )
        }
        return data.subdata(in: range)
    }

    // MARK: - Internals

    private func walk(from start: Int, to end: Int) throws -> [ISOBox] {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw ISOBoxReaderError.truncated(
                    expected: max(0, end - start),
                    available: 0
                )
            }
            var status = pm_iso_status(code: 0, expected: 0, available: 0)
            let total = pm_iso_walk(
                base,
                Int32(data.count),
                Int32(start),
                Int32(end),
                nil,
                0,
                &status
            )
            try Self.throwIfNeeded(status)
            guard total > 0 else { return [] }
            var boxes = [pm_iso_box](
                repeating: pm_iso_box(
                    type: 0,
                    start: 0,
                    size: 0,
                    header_size: 0
                ),
                count: Int(total)
            )
            let count = boxes.withUnsafeMutableBufferPointer { buffer in
                pm_iso_walk(
                    base,
                    Int32(data.count),
                    Int32(start),
                    Int32(end),
                    buffer.baseAddress,
                    Int32(buffer.count),
                    &status
                )
            }
            try Self.throwIfNeeded(status)
            return boxes.prefix(Int(count)).map { box in
                ISOBox(
                    type: Self.fourCCString(box.type),
                    range: Int(box.start)..<(Int(box.start) + Int(box.size)),
                    headerSize: Int(box.header_size)
                )
            }
        }
    }

    private static func throwIfNeeded(_ status: pm_iso_status) throws {
        if status.code == PM_ISO_TRUNCATED {
            throw ISOBoxReaderError.truncated(
                expected: Int(status.expected),
                available: Int(status.available)
            )
        }
        if status.code == PM_ISO_INVALID {
            throw ISOBoxReaderError.invalidBox("malformed")
        }
    }

    private static func fourCCString(_ type: UInt32) -> String {
        let bytes = [
            UInt8((type >> 24) & 0xFF),
            UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF),
            UInt8(type & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private func require(offset: Int, byteCount: Int) throws {
        guard offset >= 0, byteCount >= 0,
              offset + byteCount <= data.count else {
            throw ISOBoxReaderError.truncated(
                expected: byteCount,
                available: max(0, data.count - max(offset, 0))
            )
        }
    }
}

enum ISOBoxReaderError: Error, Sendable, Equatable {
    case truncated(expected: Int, available: Int)
    case invalidBox(String)

    var errorDescription: String? {
        switch self {
        case let .truncated(expected, available):
            return "ISO BMFF box is truncated (expected \(expected) bytes, got \(available))."
        case let .invalidBox(type):
            return "ISO BMFF box '\(type)' is malformed."
        }
    }
}
