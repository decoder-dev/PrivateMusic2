import XCTest
@testable import PrivateMusic

final class LibraryFeaturesTests: XCTestCase {
    func testFriendsPageUsesExactOffsetAndPreservesTotal() async throws {
        let service = service { request in
            XCTAssertEqual(request.url?.path, "/method/friends.get")
            let form = Self.form(request)
            XCTAssertEqual(form["fields"], "photo_200")
            XCTAssertEqual(form["offset"], "100")
            return #"{"response":{"count":500,"items":[{"id":7,"first_name":"A","last_name":"B"}]}}"#
        }
        let page = try await service.friends(accessToken: "test", offset: 100, count: 100)
        XCTAssertEqual(page.items.first?.id, 7)
        XCTAssertEqual(page.totalCount, 500)
        XCTAssertEqual(page.nextOffset, 101)
    }

    func testFriendMusicUsesFriendAsOwnerAndSkipsMalformedEntries() async throws {
        let service = service { request in
            XCTAssertEqual(Self.form(request)["owner_id"], "7")
            return #"{"response":{"count":5,"items":[{"id":1,"owner_id":7,"title":"T","artist":"A","duration":100},{"ad":true}]}}"#
        }
        let page = try await service.friendTracks(ownerID: 7, accessToken: "test", offset: 0, count: 100)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.nextOffset, 2)
    }

    func testFriendPlaylistsSkipMalformedEntries() async throws {
        let service = service { request in
            XCTAssertEqual(Self.form(request)["owner_id"], "7")
            return #"{"response":{"count":3,"items":[{"id":1,"owner_id":7,"title":"P","count":1},{"ad":true}]}}"#
        }
        let page = try await service.friendPlaylists(ownerID: 7, accessToken: "test", offset: 0, count: 100)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.nextOffset, 2)
    }

    func testHiddenPlaylistIsCreatedHiddenInTheInitialRequest() async throws {
        let service = service { request in
            XCTAssertEqual(request.url?.path, "/method/audio.createPlaylist")
            XCTAssertEqual(Self.form(request)["no_discover"], "1")
            return #"{"response":{"id":12,"owner_id":1,"title":"Private","count":0,"no_discover":1}}"#
        }
        let playlist = try await service.createPlaylist(title: "Private", description: "", ownerID: 1,
            hidden: true, accessToken: "test")
        XCTAssertTrue(playlist.isHidden)
        XCTAssertTrue(playlist.updatingCount(4).isHidden)
        XCTAssertEqual(try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(playlist)), playlist)
    }

    func testPlaylistVisibilityAcceptsBooleanAndLegacyMissingValue() throws {
        for (field, expected) in [("true", true), ("false", false), ("1", true), ("0", false)] {
            let data = Data("{\"id\":1,\"owner_id\":1,\"title\":\"P\",\"no_discover\":\(field)}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(Playlist.self, from: data).isHidden, expected)
        }
        let old = Data(#"{"id":1,"owner_id":1,"title":"P"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(Playlist.self, from: old).isHidden)
    }

    func testBroadcastClearOmitsAudioParameter() async throws {
        let service = service { request in
            XCTAssertEqual(request.url?.path, "/method/audio.setBroadcast")
            XCTAssertNil(Self.form(request)["audio"])
            return #"{"response":[1]}"#
        }
        try await service.broadcast(track: nil, accessToken: "test")
    }

    func testPlaybackEventWireTypesAndNoAutomaticRetry() async throws {
        var calls = 0
        let service = service { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/method/stats.trackEvents")
            let raw = try XCTUnwrap(Self.form(request)["events"])
            let events = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
            let event = try XCTUnwrap(events.first)
            XCTAssertEqual(event["e"] as? String, "music_stop_playback")
            XCTAssertEqual(event["uuid"] as? Int, 42)
            XCTAssertEqual(event["shuffle"] as? Bool, false)
            XCTAssertEqual(event["duration"] as? Int, 15)
            XCTAssertNil(event["position"])
            return #"{"error":{"error_code":3,"error_msg":"Unknown method passed"}}"#
        }
        let event = VKListeningEvent(event: "music_stop_playback", audioID: "1_2", uuid: 42,
            startTime: 100, playbackStartedAt: 100, duration: 15, trackCode: "code",
            streamingType: "online", shuffle: false, repeatMode: "none", reason: "user", state: "app")
        do {
            try await service.reportPlayback(events: [event], accessToken: "test")
            XCTFail("Expected server refusal")
        } catch { XCTAssertEqual(calls, 1) }
    }

    func testVKRefusalIsSurfaced() async throws {
        let service = service { _ in #"{"error":{"error_code":15,"error_msg":"Access denied"}}"# }
        do {
            _ = try await service.friends(accessToken: "test", offset: 0, count: 100)
            XCTFail("Must not turn a permission error into an empty friend list")
        } catch { XCTAssertEqual(error as? APIError, .server(code: 15, message: "Access denied")) }
    }

    func testUploadURLsRejectLookalikeAndInsecureHosts() {
        for string in ["http://vk.com/upload", "https://vk.com.evil.test/upload", "https://evilvk.com/upload",
                       "https://user:pass@vk.com/upload", "file:///tmp/a"] {
            XCTAssertFalse(VKUploadPolicy.accepts(URL(string: string)!))
        }
        XCTAssertTrue(VKUploadPolicy.accepts(URL(string: "https://pu.vk.com/upload")!))
        XCTAssertTrue(VKUploadPolicy.accepts(URL(string: "https://psv.userapi.com/upload")!))
    }

    func testCoverBindingUsesOpaquePhotoAndUploadHash() throws {
        let playlist = Playlist(id: 12, ownerID: 7, title: "P", count: 0)
        let upload = JSONValue.object(["photo": .string("opaque-photo"), "hash": .string("upload-hash")])
        let fields = try VKPlaylistCoverParameters.make(playlist: playlist, uploaded: upload)
        XCTAssertEqual(fields["playlist_owner_id"], "7")
        XCTAssertEqual(fields["playlist_id"], "12")
        XCTAssertEqual(fields["photo"], "opaque-photo")
        XCTAssertEqual(fields["hash"], "upload-hash")
        XCTAssertNil(fields["photo_id"])
        XCTAssertThrowsError(try VKPlaylistCoverParameters.make(playlist: playlist, uploaded: .object([:])))
    }

    func testTrackCodeSurvivesURLResolutionAndCoding() throws {
        let data = Data(#"{"id":1,"owner_id":1,"title":"T","artist":"A","duration":100,"track_code":"code"}"#.utf8)
        let track = try JSONDecoder().decode(Track.self, from: data).resolvingStreamURL(userID: 1)
        XCTAssertEqual(track.trackCode, "code")
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)).trackCode, "code")
        XCTAssertEqual(AppLogRedaction.redactFormValue(forKey: "events", value: "sensitive"), "<redacted>")
    }

    func testPagePolicyTerminatesEmptyAndOverflowPages() {
        XCTAssertNil(VKLibraryPagePolicy.next(offset: 0, received: 0, total: 100))
        XCTAssertNil(VKLibraryPagePolicy.next(offset: Int.max, received: 1, total: Int.max))
        XCTAssertNil(VKLibraryPagePolicy.next(offset: 100, received: 20, total: 120))
        XCTAssertEqual(VKLibraryPagePolicy.next(offset: 100, received: 20, total: 300), 120)
    }

    func testLongCrossfadePreparesBeforeItsFadeWindow() {
        XCTAssertTrue(PlaybackTransitionPolicy.shouldPrepareIncoming(remaining: 6.5, duration: 180,
            hasNextTrack: true, isRepeatOne: false, isAlreadyTransitioning: false, fadeSeconds: 6))
        XCTAssertTrue(PlaybackTransitionPolicy.shouldStartFade(remaining: 5.9, incomingIsReady: true,
            isAlreadyFading: false, fadeSeconds: 6))
        XCTAssertFalse(PlaybackTransitionPolicy.shouldStartFade(remaining: -1, incomingIsReady: true,
            isAlreadyFading: false, fadeSeconds: 6))
        XCTAssertFalse(PlaybackTransitionPolicy.shouldPrepareIncoming(remaining: 6, duration: 10,
            hasNextTrack: true, isRepeatOne: false, isAlreadyTransitioning: false, fadeSeconds: 6))
    }

    private func service(_ handler: @escaping (URLRequest) throws -> String) -> VKMusicService {
        FeatureURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeatureURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel(); FeatureURLProtocol.handler = nil }
        return VKMusicService(client: APIClient(baseURL: URL(string: "https://example.com")!, session: session),
            apiVersion: "5.131", initialUserID: 1, initialAccessToken: "test")
    }

    private static func form(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

@MainActor final class LibraryFeaturePersistenceTests: XCTestCase {
    func testSettingsDefaultToNoVKSharingAndClampCrossfade() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.vkBroadcastEnabled)
        XCTAssertFalse(settings.vkReportingEnabled)
        settings.crossfadeDuration = .nan
        XCTAssertEqual(settings.crossfadeDuration, 0.55)
        settings.crossfadeDuration = 100
        XCTAssertEqual(settings.crossfadeDuration, 10)
        settings.crossfadeDuration = -1
        XCTAssertEqual(settings.crossfadeDuration, 0.5)
        settings.crossfadeDuration = 6
        XCTAssertEqual(AppSettings(defaults: defaults).crossfadeDuration, 6)
    }

    func testDownloadQueueRestoresPerAccountWithoutStartingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved = LibraryDownloadSnapshot()
        saved.nextOffset = 200; saved.completed = 85; saved.total = 900
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("1.json"))
        let job = LibraryDownloadJob(directory: directory)
        job.configure(accountID: 1)
        XCTAssertEqual(job.snapshot.completed, 85)
        XCTAssertFalse(job.running)
        job.configure(accountID: 2)
        XCTAssertFalse(job.hasJob)
        job.configure(accountID: 1)
        XCTAssertEqual(job.snapshot.nextOffset, 200)
        job.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("1.json").path))
    }
}

private final class FeatureURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let data = Data(try handler(request).utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
