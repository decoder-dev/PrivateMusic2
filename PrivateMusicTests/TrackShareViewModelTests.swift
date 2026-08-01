import XCTest
@testable import PrivateMusic

@MainActor
final class TrackShareViewModelTests: XCTestCase {
    func testSuccessBecomesReady() async throws {
        let (vm, preparer) = makePreparer()
        let payload = try makePayload()
        preparer.result = .success(payload)

        vm.start(track: makeTrack(), environment: preparer)
        await vm.waitForCurrentOperation()

        XCTAssertEqual(vm.state, .ready(payload))
    }

    func testFailureBecomesFailedWithMessage() async throws {
        let (vm, preparer) = makePreparer()
        preparer.result = .failure(
            NSError(domain: "Test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Something went wrong"
            ])
        )

        vm.start(track: makeTrack(), environment: preparer)
        await vm.waitForCurrentOperation()

        let failure = try XCTUnwrap({
            guard case .failed(let value) = vm.state else { return nil }
            return value
        }())
        XCTAssertEqual(failure.title, L10n.text("Не удалось подготовить аудиофайл."))
        XCTAssertEqual(failure.message, L10n.text("Не удалось подготовить аудиофайл."))
        XCTAssertNotNil(failure.diagnosticCode)
    }

    func testCancellationErrorDoesNotBecomeFailed() async throws {
        let (vm, preparer) = makePreparer()
        preparer.result = .failure(CancellationError())

        vm.start(track: makeTrack(), environment: preparer)
        await vm.waitForCurrentOperation()

        XCTAssertEqual(vm.state, .idle)
    }

    func testActivityFinishedCleansUpOnceAndResets() async throws {
        let (vm, preparer) = makePreparer()
        let payload = try makePayload()
        preparer.result = .success(payload)

        vm.start(track: makeTrack(), environment: preparer)
        await vm.waitForCurrentOperation()
        XCTAssertEqual(vm.state, .ready(payload))

        vm.activityFinished(environment: preparer)
        vm.activityFinished(environment: preparer)

        XCTAssertEqual(vm.state, .idle)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(preparer.removedPayloads, [payload])
    }

    func testCancelInvalidatesGenerationAndCleansUp() async throws {
        let (vm, preparer) = makePreparer()
        let payload = try makePayload()
        preparer.result = .success(payload)
        preparer.shouldSuspendNextPrepare = true

        vm.start(track: makeTrack(), environment: preparer)
        await preparer.waitForPrepareStarted()

        vm.cancel(environment: preparer)
        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(preparer.removedPayloads.isEmpty)

        preparer.resumeSuspendedPrepare()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(preparer.removedPayloads, [payload])
    }

    func testStaleCompletionCannotReplaceNewerOperation() async throws {
        let (vm, preparer) = makePreparer()
        let first = try makePayload()
        let second = try makePayload()
        preparer.result = .success(first)
        preparer.shouldSuspendNextPrepare = true

        vm.start(track: makeTrack(), environment: preparer)
        await preparer.waitForPrepareStarted()

        preparer.result = .success(second)
        preparer.shouldSuspendNextPrepare = false
        vm.start(track: makeTrack(), environment: preparer)
        await vm.waitForCurrentOperation()

        XCTAssertEqual(vm.state, .ready(second))

        preparer.resumeSuspendedPrepare()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.state, .ready(second))
        XCTAssertTrue(preparer.removedPayloads.contains(first))
    }

    // MARK: - Helpers

    private func makePreparer() -> (TrackShareViewModel, MockPreparer) {
        (TrackShareViewModel(), MockPreparer())
    }

    private func makePayload() throws -> TrackSharePayload {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data("ID3audio".utf8).write(to: url)
        return .audioFile(url)
    }

    private func makeTrack() -> Track {
        Track(
            trackID: 7,
            ownerID: -42,
            title: "Title",
            artist: "Artist",
            duration: 120,
            streamURL: URL(string: "https://example.com/track.mp3"),
            artworkURL: nil
        )
    }
}

@MainActor
private final class MockPreparer: TrackSharePreparing {
    var result: Result<TrackSharePayload, Error> = .failure(CancellationError())
    var shouldSuspendNextPrepare = false
    private(set) var removedPayloads: [TrackSharePayload] = []
    private var suspension: CheckedContinuation<Void, Never>?
    private var hasPrepareStarted = false
    private var prepareStarted: CheckedContinuation<Void, Never>?

    func prepareSharePayload(
        for track: Track,
        progress: TrackExportProgressHandler?
    ) async throws -> TrackSharePayload {
        hasPrepareStarted = true
        prepareStarted?.resume()
        prepareStarted = nil
        let capturedResult = result
        if shouldSuspendNextPrepare {
            shouldSuspendNextPrepare = false
            await withCheckedContinuation { continuation in
                suspension = continuation
            }
        }
        return try capturedResult.get()
    }

    func removeSharePayload(_ payload: TrackSharePayload) async {
        removedPayloads.append(payload)
    }

    func waitForPrepareStarted() async {
        if hasPrepareStarted { return }
        await withCheckedContinuation { continuation in
            prepareStarted = continuation
        }
    }

    func resumeSuspendedPrepare() {
        suspension?.resume()
        suspension = nil
    }
}
