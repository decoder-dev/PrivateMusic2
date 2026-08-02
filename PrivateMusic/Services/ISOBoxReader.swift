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

    private let containerLimit = 4096

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
        guard start >= 0, start <= end, end <= data.count else {
            throw ISOBoxReaderError.truncated(
                expected: max(0, end - start),
                available: max(0, data.count - start)
            )
        }
        var result: [ISOBox] = []
        var offset = start
        var count = 0
        while offset + 8 <= end, count < containerLimit {
            count += 1
            let box = try parseBox(at: offset, within: end)
            result.append(box)
            offset += box.range.count
            if box.range.count == 0 { break }
        }
        return result
    }

    private func parseBox(at offset: Int, within limit: Int) throws -> ISOBox {
        try require(offset: offset, byteCount: 8)
        let size32 = try readUInt32BE(at: offset)
        let type = asciiType(at: offset + 4)

        if size32 == 0 {
            // Box runs to the end of the containing buffer.
            guard offset + 8 <= limit else {
                throw ISOBoxReaderError.truncated(
                    expected: 8,
                    available: max(0, limit - offset)
                )
            }
            return ISOBox(type: type, range: offset..<limit, headerSize: 8)
        }
        if size32 == 1 {
            // Extended 64-bit size: [size=1][type][size64]...
            try require(offset: offset, byteCount: 16)
            let size64 = try readUInt64BE(at: offset + 8)
            guard size64 <= UInt64(Int.max), size64 >= UInt64(16) else {
                throw ISOBoxReaderError.invalidBox("invalid \(type) size \(size64)")
            }
            return try finishBox(
                type: type,
                offset: offset,
                size: Int(size64),
                headerSize: 16,
                within: limit
            )
        }

        let size = Int(size32)
        guard size >= 8 else {
            throw ISOBoxReaderError.invalidBox("\(type) declares \(size) bytes")
        }
        return try finishBox(
            type: type,
            offset: offset,
            size: size,
            headerSize: 8,
            within: limit
        )
    }

    private func asciiType(at offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        let bytes = data.subdata(in: offset..<offset + 4)
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private func finishBox(
        type: String,
        offset: Int,
        size: Int,
        headerSize: Int,
        within limit: Int
    ) throws -> ISOBox {
        let remaining = limit &- offset
        guard remaining >= 0, size <= remaining else {
            throw ISOBoxReaderError.truncated(
                expected: size,
                available: max(0, remaining)
            )
        }
        return ISOBox(
            type: type,
            range: offset..<(offset + size),
            headerSize: headerSize
        )
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
