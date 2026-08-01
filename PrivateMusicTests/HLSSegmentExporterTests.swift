import AVFoundation
import XCTest
@testable import PrivateMusic

@MainActor
final class HLSSegmentExporterTests: XCTestCase {
    private let mediaPlaylist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-MEDIA-SEQUENCE:0
    #EXTINF:5,
    seg1.ts
    #EXTINF:5,
    seg2.ts
    #EXTINF:5,
    seg3.ts
    #EXT-X-ENDLIST
    """

    // MARK: - Baseline behavior

    func testSegmentProgressStartsAtZeroAndEndsAtTotal() async throws {
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (Self.successResponse(for: request), Data(self.mediaPlaylist.utf8))
            }
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        var values: [TrackExportProgress] = []
        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: ["Referer": "https://vk.com/"],
            destination: destination,
            fileSizeLimit: 150_000_000,
            progress: { values.append($0) }
        )

        let increments = values.compactMap { progress -> (Int, Int)? in
            guard case let .downloadingSegments(completed, total) = progress
            else { return nil }
            return (completed, total)
        }
        XCTAssertEqual(increments.map(\.0), [0, 1, 2, 3])
        XCTAssertEqual(increments.map(\.1), [3, 3, 3, 3])
        XCTAssertTrue(values.contains(.convertingToM4A))
        XCTAssertEqual(values.last, .convertingToM4A)
        XCTAssertNil(increments.firstIndex { $0.0 < 0 || $0.0 > $0.1 })
        try? FileManager.default.removeItem(at: parent)
    }

    func testByterangeRequestsCarryCorrectRangeHeaders() async throws {
        let byteRangePlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-BYTERANGE:100@0
        seg.ts
        #EXT-X-BYTERANGE:100
        seg.ts
        #EXT-X-ENDLIST
        """
        let lock = NSLock()
        var capturedRanges: [String] = []
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(byteRangePlaylist.utf8)
                )
            }
            if let range = request.value(forHTTPHeaderField: "Range") {
                lock.lock()
                capturedRanges.append(range)
                lock.unlock()
            }
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: [:],
            destination: destination,
            fileSizeLimit: 150_000_000
        )

        lock.lock()
        let ranges = capturedRanges.sorted()
        lock.unlock()
        XCTAssertEqual(ranges, ["bytes=0-99", "bytes=100-199"])
        try? FileManager.default.removeItem(at: parent)
    }

    func testCancellationDeletesStagingAndDestination() async throws {
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (Self.successResponse(for: request), Data(self.mediaPlaylist.utf8))
            }
            Thread.sleep(forTimeInterval: 0.3)
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        var values: [TrackExportProgress] = []
        let task = Task {
            try await exporter.exportToM4A(
                streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
                headers: [:],
                destination: destination,
                fileSizeLimit: 150_000_000,
                progress: { values.append($0) }
            )
        }
        while values.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(values.first, .downloadingSegments(completed: 0, total: 3))
        task.cancel()
        _ = try? await task.value

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: parent.path
        )
        XCTAssertTrue(contents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testKeyFailureDeletesStaging() async throws {
        let encryptedPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x000102030405060708090a0b0c0d0e0f
        #EXTINF:5,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(encryptedPlaylist.utf8)
                )
            }
            if request.url?.lastPathComponent == "key.bin" {
                return (Self.errorResponse(for: request), Data())
            }
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        do {
            try await exporter.exportToM4A(
                streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
                headers: [:],
                destination: destination,
                fileSizeLimit: 150_000_000
            )
            XCTFail("A failed key fetch must fail the export")
        } catch {
            XCTAssertNotNil(error as? HLSExportError)
        }

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: parent.path
        )
        XCTAssertTrue(contents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - EXT-X-MAP

    func testMapIsFetchedOnceAndSharedAcrossSegments() async throws {
        let fixture = try FragmentedMP4Fixture.make()
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:0.1,
        frag1.m4s
        #EXTINF:0.1,
        frag2.m4s
        #EXT-X-ENDLIST
        """
        let lock = NSLock()
        var initRequests = 0
        var segmentRequests = 0
        let exporter = makeExporter { request in
            switch request.url?.lastPathComponent {
            case "index.m3u8":
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            case "init.mp4":
                lock.lock()
                initRequests += 1
                lock.unlock()
                return (
                    Self.successResponse(for: request),
                    fixture.initialization
                )
            case "frag1.m4s":
                lock.lock()
                segmentRequests += 1
                lock.unlock()
                return (
                    Self.successResponse(for: request),
                    fixture.fragments[0]
                )
            case "frag2.m4s":
                lock.lock()
                segmentRequests += 1
                lock.unlock()
                return (
                    Self.successResponse(for: request),
                    fixture.fragments.count > 1
                        ? fixture.fragments[1]
                        : fixture.fragments[0]
                )
            default:
                return (Self.errorResponse(for: request), Data())
            }
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: ["Referer": "https://vk.com/"],
            destination: destination,
            fileSizeLimit: 150_000_000
        )

        lock.lock()
        let inits = initRequests
        let segments = segmentRequests
        lock.unlock()
        XCTAssertEqual(inits, 1)
        XCTAssertEqual(segments, 2)
        try? FileManager.default.removeItem(at: parent)
    }

    func testMapByterangeRequestsExactBytes() async throws {
        let fixture = try FragmentedMP4Fixture.make()
        let paddedInit = Self.validInitialization(paddedTo: 1000)
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="1000@0"
        #EXTINF:0.1,
        frag1.m4s
        #EXTINF:0.1,
        frag2.m4s
        #EXT-X-ENDLIST
        """
        let lock = NSLock()
        var mapRanges: [String] = []
        let exporter = makeExporter { request in
            if request.url?.lastPathComponent == "index.m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            }
            if request.url?.lastPathComponent == "init.mp4" {
                if let range = request.value(forHTTPHeaderField: "Range") {
                    lock.lock()
                    mapRanges.append(range)
                    lock.unlock()
                }
                return (Self.successResponse(for: request), paddedInit)
            }
            switch request.url?.lastPathComponent {
            case "frag1.m4s":
                return (
                    Self.successResponse(for: request),
                    fixture.fragments[0]
                )
            default:
                return (
                    Self.successResponse(for: request),
                    fixture.fragments.count > 1
                        ? fixture.fragments[1]
                        : fixture.fragments[0]
                )
            }
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: [:],
            destination: destination,
            fileSizeLimit: 150_000_000
        )

        lock.lock()
        let ranges = mapRanges.sorted()
        lock.unlock()
        XCTAssertEqual(ranges, ["bytes=0-999"])
        try? FileManager.default.removeItem(at: parent)
    }

    func testMapChangeThrowsAndCleansUp() async throws {
        let fixture = try FragmentedMP4Fixture.make()
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init1.mp4"
        #EXTINF:0.1,
        frag1.m4s
        #EXT-X-MAP:URI="init2.mp4"
        #EXTINF:0.1,
        frag2.m4s
        #EXT-X-ENDLIST
        """
        let exporter = makeExporter { request in
            switch request.url?.lastPathComponent {
            case "index.m3u8":
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            case "init1.mp4":
                return (
                    Self.successResponse(for: request),
                    fixture.initialization
                )
            case "init2.mp4":
                return (
                    Self.successResponse(for: request),
                    Self.validInitialization(paddedTo: 200)
                )
            default:
                return (
                    Self.successResponse(for: request),
                    fixture.fragments[0]
                )
            }
        }
        let (parent, destination) = makeDestination()

        do {
            try await exporter.exportToM4A(
                streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
                headers: [:],
                destination: destination,
                fileSizeLimit: 150_000_000
            )
            XCTFail("A mid-playlist map change must fail the export")
        } catch let error as HLSExportError {
            if case .changingInitializationSection = error {} else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: parent.path
        )
        XCTAssertTrue(contents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Byte ranges

    func testSegmentsInSameResourceUseExplicitRanges() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-BYTERANGE:500@1000
        seg.ts
        #EXT-X-BYTERANGE:500@1500
        seg.ts
        #EXT-X-ENDLIST
        """
        let lock = NSLock()
        var ranges: [String] = []
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            }
            if let range = request.value(forHTTPHeaderField: "Range") {
                lock.lock()
                ranges.append(range)
                lock.unlock()
            }
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: [:],
            destination: destination,
            fileSizeLimit: 150_000_000
        )

        lock.lock()
        let sorted = ranges.sorted()
        lock.unlock()
        XCTAssertEqual(sorted, ["bytes=1000-1499", "bytes=1500-1999"])
        try? FileManager.default.removeItem(at: parent)
    }

    func testImplicitByteRangeContinuesPerURL() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-BYTERANGE:100@0
        a.ts
        #EXT-X-BYTERANGE:100
        b.ts
        #EXT-X-BYTERANGE:100
        a.ts
        #EXT-X-ENDLIST
        """
        let lock = NSLock()
        var requests: [(path: String, range: String)] = []
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            }
            let path = request.url?.path ?? ""
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            lock.lock()
            requests.append((path, range))
            lock.unlock()
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: [:],
            destination: destination,
            fileSizeLimit: 150_000_000
        )

        lock.lock()
        let captured = requests
        lock.unlock()
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(
            captured
                .filter { $0.path == "/hls/a.ts" }
                .map(\.range),
            ["bytes=0-99", "bytes=100-199"]
        )
        XCTAssertEqual(
            captured
                .filter { $0.path == "/hls/b.ts" }
                .map(\.range),
            ["bytes=0-99"]
        )
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - Encryption

    func testMethodNoneClearsKey() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000000
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:5,
        seg1.ts
        #EXTINF:5,
        seg2.ts
        #EXT-X-ENDLIST
        """
        let lock = NSLock()
        var keyRequests = 0
        var segmentRequests = 0
        var values: [TrackExportProgress] = []
        let exporter = makeExporter { request in
            switch request.url?.lastPathComponent {
            case "index.m3u8":
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            case "key.bin":
                lock.lock()
                keyRequests += 1
                lock.unlock()
                return (
                    Self.successResponse(for: request),
                    Data(repeating: 0x2A, count: 16)
                )
            default:
                lock.lock()
                segmentRequests += 1
                lock.unlock()
                return (
                    Self.successResponse(for: request),
                    Data(repeating: 0x47, count: 512)
                )
            }
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: [:],
            destination: destination,
            fileSizeLimit: 150_000_000,
            progress: { values.append($0) }
        )

        lock.lock()
        let keys = keyRequests
        let segments = segmentRequests
        lock.unlock()
        XCTAssertEqual(keys, 0)
        XCTAssertEqual(segments, 2)
        XCTAssertEqual(values.last, .convertingToM4A)
        try? FileManager.default.removeItem(at: parent)
    }

    func testSampleAESThrowsUnsupportedEncryption() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
        #EXTINF:5,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            }
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        do {
            try await exporter.exportToM4A(
                streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
                headers: [:],
                destination: destination,
                fileSizeLimit: 150_000_000
            )
            XCTFail("SAMPLE-AES must be rejected")
        } catch let error as HLSExportError {
            if case .unsupportedEncryptionMethod("SAMPLE-AES") = error {} else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        try? FileManager.default.removeItem(at: parent)
    }

    func testEncryptedMapWithoutExplicitIVThrows() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:0.1,
        frag1.m4s
        #EXT-X-ENDLIST
        """
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            }
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        do {
            try await exporter.exportToM4A(
                streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
                headers: [:],
                destination: destination,
                fileSizeLimit: 150_000_000
            )
            XCTFail("An encrypted map without an explicit IV must be rejected")
        } catch let error as HLSExportError {
            if case .encryptedInitializationRequiresExplicitIV = error {} else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - Header propagation

    func testHeadersPropagateToAllRequests() async throws {
        let fixture = try FragmentedMP4Fixture.make()
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000000
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:0.1,
        frag1.m4s
        #EXT-X-ENDLIST
        """
        let lock = NSLock()
        var observed: [[String: String]] = []
        let exporter = makeExporter { request in
            lock.lock()
            observed.append(request.allHTTPHeaderFields ?? [:])
            lock.unlock()
            switch request.url?.lastPathComponent {
            case "index.m3u8":
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            case "key.bin":
                return (
                    Self.successResponse(for: request),
                    Data(repeating: 0x2A, count: 16)
                )
            case "init.mp4":
                return (
                    Self.successResponse(for: request),
                    fixture.initialization
                )
            default:
                return (
                    Self.successResponse(for: request),
                    fixture.fragments[0]
                )
            }
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: [
                "Referer": "https://vk.com/",
                "User-Agent": "PrivateMusicTests",
            ],
            destination: destination,
            fileSizeLimit: 150_000_000
        )

        lock.lock()
        let headers = observed
        lock.unlock()
        XCTAssertEqual(headers.count, 3)
        XCTAssertTrue(headers.allSatisfy {
            $0["Referer"] == "https://vk.com/"
                && $0["User-Agent"] == "PrivateMusicTests"
        })
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - Container detection

    func testMPEGTSDetectionSupportsPacketSizes() {
        XCTAssertTrue(
            HLSSegmentExporter.looksLikeMPEGTS(
                Data(Self.tsPackets(size: 188, count: 2))
            )
        )
        XCTAssertTrue(
            HLSSegmentExporter.looksLikeMPEGTS(
                Data(Self.tsPackets(size: 192, count: 2))
            )
        )
        XCTAssertTrue(
            HLSSegmentExporter.looksLikeMPEGTS(
                Data(Self.tsPackets(size: 204, count: 2))
            )
        )
        XCTAssertFalse(
            HLSSegmentExporter.looksLikeMPEGTS(
                Data(repeating: 0x00, count: 512)
            )
        )
    }

    func testFragmentedMP4BoxDetection() throws {
        let initialization = Self.validInitialization(paddedTo: 120)
        let fragment = Self.mp4Box("moof", payload: Data("x".utf8))
            + Self.mp4Box("mdat", payload: Data("y".utf8))
        XCTAssertTrue(
            HLSSegmentExporter.containsBox(
                initialization,
                types: ["ftyp", "moov"]
            )
        )
        XCTAssertTrue(
            HLSSegmentExporter.containsBox(
                fragment,
                types: ["moof", "mdat"]
            )
        )
        XCTAssertNoThrow(
            try HLSSegmentExporter.detectContainer(
                initializationData: initialization,
                firstSegmentData: fragment
            )
        )
        XCTAssertThrowsError(
            try HLSSegmentExporter.detectContainer(
                initializationData: initialization,
                firstSegmentData: Data(repeating: 0x47, count: 512)
            )
        )
        let missingMoov = Self.mp4Box("ftyp", payload: Data("isom".utf8))
        XCTAssertThrowsError(
            try HLSSegmentExporter.detectContainer(
                initializationData: missingMoov,
                firstSegmentData: fragment
            )
        )
    }

    func testADTSDetection() throws {
        let adts = Data([0xFF, 0xF1]) + Data(count: 128)
        XCTAssertTrue(HLSSegmentExporter.looksLikeADTS(adts))
        XCTAssertFalse(
            HLSSegmentExporter.looksLikeADTS(
                Data([0x00, 0xF1]) + Data(count: 128)
            )
        )
        XCTAssertNoThrow(
            try HLSSegmentExporter.detectContainer(
                initializationData: nil,
                firstSegmentData: adts
            )
        )
    }

    func testMP3Detection() throws {
        XCTAssertTrue(
            HLSSegmentExporter.looksLikeMP3(
                Data("ID3".utf8) + Data(count: 32)
            )
        )
        XCTAssertTrue(
            HLSSegmentExporter.looksLikeMP3(
                Data([0xFF, 0xFB, 0x90]) + Data(count: 32)
            )
        )
        XCTAssertFalse(
            HLSSegmentExporter.looksLikeMP3(
                Data([0xFF, 0xE0]) + Data(count: 32)
            )
        )
        XCTAssertNoThrow(
            try HLSSegmentExporter.detectContainer(
                initializationData: nil,
                firstSegmentData: Data("ID3".utf8) + Data(count: 64)
            )
        )
    }

    func testUnknownContainerIsRejected() {
        XCTAssertThrowsError(
            try HLSSegmentExporter.detectContainer(
                initializationData: nil,
                firstSegmentData: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01])
            )
        )
    }

    // MARK: - Container-specific pipelines

    func testADTSPlaylistStagesAACAndReachesTranscode() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:5,
        seg1.aac
        #EXTINF:5,
        seg2.aac
        #EXT-X-ENDLIST
        """
        let adtsData = Data([0xFF, 0xF1]) + Data(count: 512)
        var values: [TrackExportProgress] = []
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            }
            return (Self.successResponse(for: request), adtsData)
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: [:],
            destination: destination,
            fileSizeLimit: 150_000_000,
            progress: { values.append($0) }
        )

        XCTAssertTrue(values.contains(.downloadingSegments(completed: 2, total: 2)))
        XCTAssertEqual(values.last, .convertingToM4A)
        try? FileManager.default.removeItem(at: parent)
    }

    func testMP3PlaylistStagesMP3AndReachesTranscode() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:5,
        seg1.mp3
        #EXTINF:5,
        seg2.mp3
        #EXT-X-ENDLIST
        """
        let mp3Data = Data("ID3".utf8) + Data(count: 512)
        var values: [TrackExportProgress] = []
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            }
            return (Self.successResponse(for: request), mp3Data)
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: [:],
            destination: destination,
            fileSizeLimit: 150_000_000,
            progress: { values.append($0) }
        )

        XCTAssertTrue(values.contains(.downloadingSegments(completed: 2, total: 2)))
        XCTAssertEqual(values.last, .convertingToM4A)
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - Full integration

    func testFragmentedMP4EndToEndProducesPlayableM4A() async throws {
        let fixture = try FragmentedMP4Fixture.make()
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:0.1,
        frag1.m4s
        #EXTINF:0.1,
        frag2.m4s
        #EXT-X-ENDLIST
        """
        var values: [TrackExportProgress] = []
        let exporter = makeExporter { request in
            switch request.url?.lastPathComponent {
            case "index.m3u8":
                return (
                    Self.successResponse(for: request),
                    Data(playlist.utf8)
                )
            case "init.mp4":
                return (
                    Self.successResponse(for: request),
                    fixture.initialization
                )
            case "frag1.m4s":
                return (
                    Self.successResponse(for: request),
                    fixture.fragments[0]
                )
            default:
                return (
                    Self.successResponse(for: request),
                    fixture.fragments.count > 1
                        ? fixture.fragments[1]
                        : fixture.fragments[0]
                )
            }
        }
        let (parent, destination) = makeDestination()

        do {
            try await exporter.exportToM4A(
                streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
                headers: ["Referer": "https://vk.com/"],
                destination: destination,
                fileSizeLimit: 150_000_000,
                progress: { values.append($0) }
            )
        } catch {
            XCTFail("Export failed: \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let size = (
            try? FileManager.default.attributesOfItem(
                atPath: destination.path
            )[.size] as? Int64
        ) ?? 0
        XCTAssertGreaterThan(size, 0)
        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty)
        XCTAssertEqual(values.last, .convertingToM4A)
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - Error hygiene

    func testHTTPErrorDoesNotLeakURLQuery() async throws {
        let exporter = makeExporter { request in
            (Self.errorResponse(for: request), Data())
        }
        let (parent, destination) = makeDestination()

        do {
            try await exporter.exportToM4A(
                streamURL: URL(
                    string: "https://example.com/hls/index.m3u8?token=SECRET123"
                )!,
                headers: [:],
                destination: destination,
                fileSizeLimit: 150_000_000
            )
            XCTFail("An HTTP error must fail the export")
        } catch {
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("SECRET123"))
            XCTAssertFalse(description.contains("example.com"))
        }
        try? FileManager.default.removeItem(at: parent)
    }

    // MARK: - Helpers

    private func makeExporter(
        _ handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)
    ) -> HLSSegmentExporter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        HLSURLProtocol.handler = handler
        return HLSSegmentExporter(
            session: URLSession(configuration: configuration)
        )
    }

    private func makeDestination() -> (URL, URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HLSSegmentExporterTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        return (parent, parent.appendingPathComponent("out.m4a"))
    }

    private static func successResponse(
        for request: URLRequest
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com/")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func errorResponse(
        for request: URLRequest
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com/")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func tsPackets(size: Int, count: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0x00, count: size * count)
        for index in 0..<count {
            data[index * size] = 0x47
        }
        return data
    }

    private static func mp4Box(_ type: String, payload: Data) -> Data {
        var data = Data()
        let size = UInt32(payload.count + 8).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: size) { [UInt8]($0) })
        data.append(contentsOf: type.utf8)
        data.append(payload)
        return data
    }

    /// `ftyp` + `moov` boxes padded to a fixed byte length (simulates a
    /// `BYTERANGE`-addressed initialization section in one resource).
    private static func validInitialization(paddedTo length: Int) -> Data {
        let boxes = mp4Box("ftyp", payload: Data("isom".utf8))
            + mp4Box("moov", payload: Data("mvex".utf8))
        guard boxes.count < length else { return boxes }
        return boxes + Data(count: length - boxes.count)
    }
}

private final class HLSURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unknown)
            )
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
