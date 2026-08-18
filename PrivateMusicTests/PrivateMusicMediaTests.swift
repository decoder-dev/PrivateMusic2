import CommonCrypto
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

    func testAES128CBCDecryptRoundTrip() {
        let key = Data(repeating: 0x2A, count: Int(PM_AES128_KEY_BYTES))
        let iv = Data(repeating: 0x19, count: Int(PM_AES128_IV_BYTES))
        let plaintext = Data("PrivateMusic HLS segment payload".utf8)
        let ciphertext = encryptAES128CBC(plaintext, key: key, iv: iv)

        var output = Data(
            count: ciphertext.count + Int(PM_AES128_BLOCK_BYTES)
        )
        var outputLength: Int32 = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        pm_aes128_cbc_decrypt(
                            cipherBytes.baseAddress?.assumingMemoryBound(
                                to: UInt8.self
                            ),
                            Int32(ciphertext.count),
                            keyBytes.baseAddress?.assumingMemoryBound(
                                to: UInt8.self
                            ),
                            ivBytes.baseAddress?.assumingMemoryBound(
                                to: UInt8.self
                            ),
                            outBytes.baseAddress?.assumingMemoryBound(
                                to: UInt8.self
                            ),
                            Int32(outBytes.count),
                            &outputLength
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, PM_AES128_OK)
        let decrypted = output
        XCTAssertEqual(decrypted.prefix(Int(outputLength)), plaintext)
    }

    func testAES128CBCDecryptRejectsNonBlockAlignedCiphertext() {
        var outputLength: Int32 = 0
        var output = [UInt8](repeating: 0, count: 32)
        let key = [UInt8](repeating: 1, count: Int(PM_AES128_KEY_BYTES))
        let iv = [UInt8](repeating: 2, count: Int(PM_AES128_IV_BYTES))
        let ciphertext = [UInt8](repeating: 0, count: 15)
        let status = pm_aes128_cbc_decrypt(
            ciphertext,
            15,
            key,
            iv,
            &output,
            32,
            &outputLength
        )
        XCTAssertEqual(status, PM_AES128_OUTPUT_TOO_SMALL)
    }

    func testVKUnmaskRestoresAMaskedStreamURL() {
        let masked = URL(
            string: "https://vk.com/mp3/audio_api_unavailable.mp3?extra=DhbTBY4VDwLHBs8UCNbWlZ0Ozxn1yxnKB2L2AhbOCY4ZyW#cZK5"
        )!
        XCTAssertEqual(
            VKAudioURLResolver.resolve(masked, userID: 12_345)?.absoluteString,
            "https://psv4.userapi.com/audio.mp3"
        )
        XCTAssertEqual(VKAudioURLResolver.resolve(masked, userID: nil), nil)
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

    func testCMAFFragmentExtractsSamplesWithoutSwiftTRUNArrays() throws {
        let payload = Data("AAAABBBB".utf8)
        let fragment = Self.cmafFragment(
            samples: [(1024, 4), (1024, 4)],
            payload: payload
        )
        var decodeTime: Int64? = nil
        let samples = try CMAFAudioDemuxer().parseFragment(
            fragment,
            initialization: Self.audioInit(),
            decodeTime: &decodeTime
        )
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].data, Data("AAAA".utf8))
        XCTAssertEqual(samples[1].data, Data("BBBB".utf8))
        XCTAssertEqual(samples[0].decodeTime, 1000)
        XCTAssertEqual(samples[1].decodeTime, 2024)
        XCTAssertEqual(samples[0].duration, 1024)
        XCTAssertEqual(decodeTime, 3048)
    }

    func testCMAFFragmentContinuesDecodeTimeWhenTFDTIsOmitted() throws {
        let fragment = Self.cmafFragment(
            decodeTime: nil,
            samples: [(1024, 4)],
            payload: Data("AAAA".utf8)
        )
        var decodeTime: Int64? = 5000
        let samples = try CMAFAudioDemuxer().parseFragment(
            fragment,
            initialization: Self.audioInit(),
            decodeTime: &decodeTime
        )
        XCTAssertEqual(samples.first?.decodeTime, 5000)
        XCTAssertEqual(decodeTime, 6024)
    }

    func testCMAFFragmentRejectsTrackMismatchAndMissingSize() {
        let payload = Data("AAAA".utf8)
        let mismatched = Self.cmafFragment(
            trackID: 2,
            samples: [(1024, 4)],
            payload: payload
        )
        var decodeTime: Int64? = nil
        XCTAssertThrowsError(
            try CMAFAudioDemuxer().parseFragment(
                mismatched,
                initialization: Self.audioInit(trackID: 1),
                decodeTime: &decodeTime
            )
        ) { error in
            guard case CMAFAudioDemuxer.CMAFError.trackIDMismatch(
                expected: 1,
                found: 2
            ) = error else {
                return XCTFail("expected track mismatch, got \(error)")
            }
        }

        let noSize = Self.cmafFragment(
            samples: [(1024, 4)],
            payload: payload,
            trunFlags: 0x000001
        )
        XCTAssertThrowsError(
            try CMAFAudioDemuxer().parseFragment(
                noSize,
                initialization: Self.audioInit(),
                decodeTime: &decodeTime
            )
        ) { error in
            guard case CMAFAudioDemuxer.CMAFError.missingSampleSize = error else {
                return XCTFail("expected missing size, got \(error)")
            }
        }
    }

    private static func audioInit(trackID: UInt32 = 1) -> CMAFAudioDemuxer.InitializationInfo {
        CMAFAudioDemuxer.InitializationInfo(
            trackID: trackID,
            timescale: 44_100,
            sampleRate: 44_100,
            channelCount: 2,
            codec: .aac,
            audioSpecificConfig: nil,
            elementaryStreamDescriptor: nil,
            defaultSampleDuration: nil,
            defaultSampleSize: nil,
            defaultSampleFlags: nil
        )
    }

    private static func u32(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 4)
    }

    private static func u64(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 8)
    }

    private static func cmafFragment(
        trackID: UInt32 = 1,
        decodeTime: UInt64? = 1000,
        samples: [(UInt32, UInt32)],
        payload: Data,
        trunFlags: UInt32 = 0x000001 | 0x000100 | 0x000200
    ) -> Data {
        let mfhd = isoBox("mfhd", payload: u32(0))
        let tfhd = isoBox("tfhd", payload: u32(0x00020000) + u32(trackID))
        var inner = tfhd
        if let decodeTime {
            inner.append(
                isoBox("tfdt", payload: u32(0x01000000) + u64(decodeTime))
            )
        }
        var entries = Data()
        for sample in samples {
            if trunFlags & 0x000100 != 0 {
                entries.append(u32(sample.0))
            }
            if trunFlags & 0x000200 != 0 {
                entries.append(u32(sample.1))
            }
        }
        let sampleCount = UInt32(max(samples.count, 1))
        func trunBox(dataOffset: UInt32) -> Data {
            var body = u32(trunFlags) + u32(sampleCount)
            if trunFlags & 0x000001 != 0 {
                body.append(u32(dataOffset))
            }
            body.append(entries)
            return isoBox("trun", payload: body)
        }
        let placeholder = isoBox(
            "moof",
            payload: mfhd + isoBox("traf", payload: inner + trunBox(dataOffset: 0))
        )
        let dataOffset = UInt32(placeholder.count + 8)
        let moof = isoBox(
            "moof",
            payload: mfhd + isoBox("traf", payload: inner + trunBox(dataOffset: dataOffset))
        )
        return moof + isoBox("mdat", payload: payload)
    }

    private static func isoBox(_ type: String, payload: Data) -> Data {
        precondition(type.utf8.count == 4)
        var size = UInt32(8 + payload.count).bigEndian
        var data = Data(bytes: &size, count: 4)
        data.append(contentsOf: type.utf8)
        data.append(payload)
        return data
    }

    private func encryptAES128CBC(
        _ plaintext: Data,
        key: Data,
        iv: Data
    ) -> Data {
        let capacity = plaintext.count + Int(PM_AES128_BLOCK_BYTES)
        var output = Data(count: capacity)
        var outputLength = 0
        var cryptStatus: CCCryptorStatus = CCCryptorStatus(kCCSuccess)
        output.withUnsafeMutableBytes { outputBytes in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        cryptStatus = CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plaintextBytes.baseAddress,
                            plaintext.count,
                            outputBytes.baseAddress,
                            capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        XCTAssertEqual(Int32(cryptStatus), Int32(kCCSuccess))
        let encrypted = output
        return Data(encrypted.prefix(outputLength))
    }
}
