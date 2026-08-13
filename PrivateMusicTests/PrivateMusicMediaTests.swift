import XCTest
@testable import PrivateMusic

final class PrivateMusicMediaTests: XCTestCase {
    func testISOWalkReadsFtypAndMoov() throws {
        let data = Self.isoBox("ftyp", payload: Data("isom".utf8))
            + Self.isoBox("moov", payload: Data("x".utf8))
        let boxes = try ISOBoxReader(data).boxes()
        XCTAssertEqual(boxes.map(\.type), ["ftyp", "moov"])
        XCTAssertEqual(boxes[0].headerSize, 8)
        XCTAssertEqual(
            boxes[0].range,
            0..<(8 + 4)
        )
    }

    func testISOWalkThrowsOnTruncatedBox() {
        let complete = Self.isoBox("moov", payload: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(
            try ISOBoxReader(Data(complete.prefix(10))).boxes()
        ) { error in
            guard case ISOBoxReaderError.truncated = error else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testISOContainsTypesMatchesHLSScanner() {
        let initialization = Self.isoBox("ftyp", payload: Data("isom".utf8))
            + Self.isoBox("moov", payload: Data("mvex".utf8))
        XCTAssertTrue(
            HLSSegmentExporter.containsBox(
                initialization,
                types: ["ftyp", "moov"]
            )
        )
        XCTAssertFalse(
            HLSSegmentExporter.containsBox(
                Self.isoBox("ftyp", payload: Data("isom".utf8)),
                types: ["ftyp", "moov"]
            )
        )
        let fragment = Self.isoBox("moof", payload: Data("x".utf8))
            + Self.isoBox("mdat", payload: Data("y".utf8))
        XCTAssertTrue(
            HLSSegmentExporter.containsBox(fragment, types: ["moof", "mdat"])
        )
    }

    func testLoadedAheadFoldTakesTheFarthestFiniteEnd() {
        let ends: [Double] = [5, 12, .nan, 8]
        let ahead = ends.withUnsafeBufferPointer { buffer in
            pm_buffer_max_loaded_ahead(10, buffer.baseAddress, 4)
        }
        XCTAssertEqual(ahead, 2, accuracy: 0.000_001)
        let empty = pm_buffer_max_loaded_ahead(10, nil, 0)
        XCTAssertEqual(empty, 0)
        let past = ends.withUnsafeBufferPointer { buffer in
            pm_buffer_max_loaded_ahead(20, buffer.baseAddress, 4)
        }
        XCTAssertEqual(past, 0)
        let nonFinitePosition = ends.withUnsafeBufferPointer { buffer in
            pm_buffer_max_loaded_ahead(.nan, buffer.baseAddress, 4)
        }
        XCTAssertEqual(nonFinitePosition, 0)
    }

    func testVKUnmaskRestoresAMaskedStreamURL() {
        let masked = URL(
            string: "https://vk.com/mp3/audio_api_unavailable.mp3?extra=DhbTBY4VDwLHBs8UCNbWlZ0Ozxn1yxnKB2L2AhbOCY4ZyW#cZK5"
        )!
        XCTAssertEqual(
            VKAudioURLResolver.resolve(masked, userID: 12_345)?.absoluteString,
            "https://psv4.userapi.com/audio.mp3"
        )
        XCTAssertEqual(VKAudioURLResolver.resolve(masked, userID: nil), masked)
        XCTAssertNil(VKAudioURLResolver.resolve(masked, userID: 1))
    }

    func testMPEGTSPacketSizeDetects188BytePackets() {
        var packets = Data()
        for _ in 0..<3 {
            var packet = Data(repeating: 0, count: 188)
            packet[0] = 0x47
            packets.append(packet)
        }
        let size = packets.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return pm_mpegts_packet_size(base, Int32(packets.count))
        }
        XCTAssertEqual(size, 188)
        XCTAssertEqual(pm_mpegts_packet_size(nil, 0), 0)
    }

    private static func isoBox(_ type: String, payload: Data) -> Data {
        precondition(type.utf8.count == 4)
        var size = UInt32(8 + payload.count).bigEndian
        var data = Data(bytes: &size, count: 4)
        data.append(contentsOf: type.utf8)
        data.append(payload)
        return data
    }
}
