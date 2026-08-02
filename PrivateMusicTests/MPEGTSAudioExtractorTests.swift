import XCTest
@testable import PrivateMusic

final class MPEGTSAudioExtractorTests: XCTestCase {
    func testExtractsADTSFromMPEGTSWithPATAndPMT() {
        let adts = Self.adtsFrame(length: 64)
        let ts = Self.tsStream(
            audioPID: 0x0100,
            streamType: 0x0F,
            elementaryPayload: adts
        )

        let extracted = MPEGTSAudioExtractor.extractAudio(from: ts)
        XCTAssertEqual(extracted?.kind, .adtsAAC)
        XCTAssertEqual(extracted?.data, adts)
    }

    func testReturnsNilForNonTSData() {
        let adts = Self.adtsFrame(length: 48)
        XCTAssertNil(MPEGTSAudioExtractor.extractAudio(from: adts))
    }

    func testExtractAudioFileWritesElementaryWithoutRequiringHeapCopyAPI() throws {
        let adts = Self.adtsFrame(length: 64)
        let ts = Self.tsStream(
            audioPID: 0x0100,
            streamType: 0x0F,
            elementaryPayload: adts
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpegts-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("stitch.ts")
        try ts.write(to: sourceURL)

        let demuxed = try MPEGTSAudioExtractor.extractAudioFile(
            from: sourceURL,
            toDirectory: directory
        )
        XCTAssertEqual(demuxed?.kind, .adtsAAC)
        let written = try Data(contentsOf: try XCTUnwrap(demuxed?.url))
        XCTAssertEqual(written, adts)
    }

    func testPESScanFallbackWithoutPAT() {
        let adts = Self.adtsFrame(length: 80)
        // Only PES packets on audio PID — no PAT/PMT tables.
        var packets = Data()
        packets.append(contentsOf: Self.tsPacket(
            pid: 0x0100,
            payloadUnitStart: true,
            payload: Self.pesPacket(streamID: 0xC0, payload: adts)
        ))
        packets.append(contentsOf: Self.tsPacket(
            pid: 0x0100,
            payloadUnitStart: false,
            payload: Data()
        ))

        let extracted = MPEGTSAudioExtractor.extractAudio(from: packets)
        XCTAssertEqual(extracted?.kind, .adtsAAC)
        XCTAssertEqual(extracted?.data, adts)
    }

    // MARK: - Fixtures

    private static func adtsFrame(length: Int) -> Data {
        precondition(length >= 7)
        var frame = Data(repeating: 0x11, count: length)
        frame[0] = 0xFF
        frame[1] = 0xF1
        frame[2] = 0x50
        frame[3] = 0x80
        let size = length
        frame[3] |= UInt8((size >> 11) & 0x03)
        frame[4] = UInt8((size >> 3) & 0xFF)
        frame[5] = UInt8((size & 0x07) << 5)
        frame[6] = 0x00
        return frame
    }

    private static func tsStream(
        audioPID: Int,
        streamType: UInt8,
        elementaryPayload: Data
    ) -> Data {
        var data = Data()
        data.append(contentsOf: tsPacket(
            pid: 0x0000,
            payloadUnitStart: true,
            payload: patSection(pmtPID: 0x0101)
        ))
        data.append(contentsOf: tsPacket(
            pid: 0x0101,
            payloadUnitStart: true,
            payload: pmtSection(
                audioPID: audioPID,
                streamType: streamType
            )
        ))
        data.append(contentsOf: tsPacket(
            pid: audioPID,
            payloadUnitStart: true,
            payload: pesPacket(streamID: 0xC0, payload: elementaryPayload)
        ))
        return data
    }

    private static func patSection(pmtPID: Int) -> Data {
        var section = Data([
            0x00, // pointer
            0x00, // table_id PAT
            0xB0, 0x0D, // section syntax + length 13
            0x00, 0x01, // transport_stream_id
            0xC1, // version/current
            0x00, 0x00, // section/last section
            0x00, 0x01, // program_number
            UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)),
            UInt8(pmtPID & 0xFF),
            0x00, 0x00, 0x00, 0x00 // CRC placeholder
        ])
        // Ensure pointer + section fits a TS payload.
        return section
    }

    private static func pmtSection(
        audioPID: Int,
        streamType: UInt8
    ) -> Data {
        Data([
            0x00, // pointer
            0x02, // table_id PMT
            0xB0, 0x12, // length
            0x00, 0x01, // program_number
            0xC1,
            0x00, 0x00,
            0xE0, 0x20, // PCR PID
            0xF0, 0x00, // program info length
            streamType,
            UInt8(0xE0 | ((audioPID >> 8) & 0x1F)),
            UInt8(audioPID & 0xFF),
            0xF0, 0x00, // ES info length
            0x00, 0x00, 0x00, 0x00 // CRC placeholder
        ])
    }

    private static func pesPacket(streamID: UInt8, payload: Data) -> Data {
        var packet = Data([
            0x00, 0x00, 0x01,
            streamID,
            0x00, 0x00, // length filled below
            0x80, // marker bits
            0x00, // flags
            0x00 // header data length
        ])
        packet.append(payload)
        let length = packet.count - 6
        packet[4] = UInt8((length >> 8) & 0xFF)
        packet[5] = UInt8(length & 0xFF)
        return packet
    }

    private static func tsPacket(
        pid: Int,
        payloadUnitStart: Bool,
        payload: Data
    ) -> Data {
        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8(
            (payloadUnitStart ? 0x40 : 0x00) | ((pid >> 8) & 0x1F)
        )
        packet[2] = UInt8(pid & 0xFF)

        if payload.isEmpty {
            // Adaptation-only stuffing packet.
            packet[3] = 0x20
            packet[4] = 183
            packet[5] = 0x00
            return packet
        }

        if payload.count >= 184 {
            packet[3] = 0x10
            packet.replaceSubrange(4..<188, with: payload.prefix(184))
            return packet
        }

        // Pad short payloads with an adaptation field so 0xFF stuffing is
        // not mistaken for PES/ADTS bytes.
        let adaptationBody = 183 - payload.count
        packet[3] = 0x30
        packet[4] = UInt8(adaptationBody)
        if adaptationBody > 0 {
            packet[5] = 0x00
        }
        let payloadOffset = 5 + adaptationBody
        packet.replaceSubrange(
            payloadOffset..<(payloadOffset + payload.count),
            with: payload
        )
        return packet
    }
}
