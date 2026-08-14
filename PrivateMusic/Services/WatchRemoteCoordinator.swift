import Foundation
@preconcurrency import WatchConnectivity

/// Mirrors the phone player's latest state to the paired Apple Watch and
/// routes transport commands back to the existing `AudioPlayer`.
@MainActor
final class WatchRemoteCoordinator: NSObject {
    private weak var player: AudioPlayer?
    private let session: WCSession?
    private var playerObservation: ObservationLoop.Token?
    private var driftTask: Task<Void, Never>?
    private var lastState: WatchRemoteState?
    private var pendingPushTask: Task<Void, Never>?
    private var pendingForcePush = false
    private var canControlPlayback: @MainActor () -> Bool = { true }
    private var isLiked: @MainActor (Track) -> Bool = { _ in false }
    private var likeCurrent: (@MainActor (Track) async -> Bool)?
    private var unlikeCurrent: (@MainActor (Track) async -> Bool)?

    init(player: AudioPlayer) {
        self.player = player
        self.session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    func start() {
        guard let session, player != nil else { return }
        session.delegate = self
        session.activate()

        playerObservation = ObservationLoop.start { [weak self] in
            guard let self, let player = self.player else { return }
            _ = player.queue
            _ = player.currentIndex
            _ = player.isPlaying
            _ = player.duration
            _ = player.isBuffering
            _ = player.queueSource
            self.markNeedsPush()
        }
        driftTask?.cancel()
        driftTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(
                        WatchStatePushCoalescingPolicy.driftCorrectionSeconds
                    )
                )
                guard !Task.isCancelled else { return }
                self?.markNeedsPush()
            }
        }
    }

    func configureControlGate(
        _ gate: @escaping @MainActor () -> Bool
    ) {
        canControlPlayback = gate
    }

    func configureLibrary(
        isLiked: @escaping @MainActor (Track) -> Bool,
        likeCurrent: @escaping @MainActor (Track) async -> Bool,
        unlikeCurrent: @escaping @MainActor (Track) async -> Bool
    ) {
        self.isLiked = isLiked
        self.likeCurrent = likeCurrent
        self.unlikeCurrent = unlikeCurrent
    }

    private func currentState() -> WatchRemoteState {
        guard let player, let track = player.currentTrack else {
            return .empty
        }
        let mixQueue: Bool = {
            if case .mix = player.queueSource { return true }
            return false
        }()
        let snapshot = WatchQueueSnapshotPolicy.window(
            items: player.queue.map { queued in
                WatchQueueItem(
                    trackID: queued.id,
                    title: queued.title,
                    artist: queued.artist
                )
            },
            currentIndex: player.currentIndex
        )
        return WatchRemoteState(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            artworkURL: track.artworkURL,
            isPlaying: player.isPlaying,
            isBuffering: player.isBuffering,
            elapsed: player.elapsedTime,
            duration: player.duration > 0 ? player.duration : track.duration,
            snapshotDate: Date(),
            isLiked: isLiked(track),
            isMixQueue: mixQueue,
            queue: snapshot.items,
            currentQueueIndex: snapshot.currentIndex
        )
    }

    private func markNeedsPush(force: Bool = false) {
        pendingForcePush = WatchStatePushCoalescingPolicy.mergedForce(
            pending: pendingForcePush,
            incoming: force
        )
        guard pendingPushTask == nil else { return }
        pendingPushTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            let force = pendingForcePush
            pendingForcePush = false
            pendingPushTask = nil
            pushLatestState(force: force)
        }
    }

    private func pushLatestState(force: Bool = false) {
        guard let session,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            return
        }
        let state = currentState()
        guard force || state != lastState else { return }
        do {
            try session.updateApplicationContext(state.context)
            lastState = state
        } catch {
            // A later player update replaces this context, so no retry queue
            // is needed for latest-state synchronization.
        }
    }

    private func reply(accepted: Bool) -> [String: Any] {
        var context = currentState().context
        context[WatchRemoteMessageKey.accepted] = accepted
        return context
    }

    private func handle(_ envelope: WatchRemoteCommandEnvelope) -> [String: Any] {
        guard let player,
              canControlPlayback() else {
            return reply(accepted: false)
        }
        guard envelope.isValid(
            at: Date(),
            currentTrackID: player.currentTrack?.id,
            queuedTrackIDs: player.queue.map(\.id)
        ) else {
            return reply(accepted: false)
        }
        switch envelope.command {
        case .togglePlayPause:
            player.playPause()
            markNeedsPush(force: true)
            return reply(accepted: true)
        case .next:
            player.next()
            markNeedsPush(force: true)
            return reply(accepted: true)
        case .previous:
            player.previous()
            markNeedsPush(force: true)
            return reply(accepted: true)
        case .likeCurrent:
            guard let track = player.currentTrack,
                  let likeCurrent else {
                return reply(accepted: false)
            }
            // Reply after the async like finishes via a synchronous false if
            // we cannot start; WCSession reply must be immediate, so accept
            // optimistically and push state when done.
            Task { @MainActor [weak self] in
                _ = await likeCurrent(track)
                self?.markNeedsPush(force: true)
            }
            return reply(accepted: true)
        case .unlikeCurrent:
            guard let track = player.currentTrack,
                  let unlikeCurrent else {
                return reply(accepted: false)
            }
            Task { @MainActor [weak self] in
                _ = await unlikeCurrent(track)
                self?.markNeedsPush(force: true)
            }
            return reply(accepted: true)
        case .playQueueItem:
            guard let trackID = envelope.trackID,
                  let index = player.queue.firstIndex(where: { $0.id == trackID })
            else {
                return reply(accepted: false)
            }
            player.jump(to: index)
            markNeedsPush(force: true)
            return reply(accepted: true)
        }
    }
}

enum WatchStatePushCoalescingPolicy {
    /// Progress-only pushes; transport / track changes still flush immediately.
    static let driftCorrectionSeconds: TimeInterval =
        WatchRemoteState.elapsedBucketSeconds

    static func mergedForce(pending: Bool, incoming: Bool) -> Bool {
        pending || incoming
    }
}

private struct WatchRemoteReplyPayload: @unchecked Sendable {
    let values: [String: Any]
}

extension WatchRemoteCoordinator: @preconcurrency WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            self?.markNeedsPush(force: true)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.markNeedsPush(force: true)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let envelope = WatchRemoteCommandEnvelope(message: message)
        Task { [weak self] in
            let payload = await MainActor.run { [weak self] () -> WatchRemoteReplyPayload in
                guard let self else {
                    return WatchRemoteReplyPayload(
                        values: [WatchRemoteMessageKey.accepted: false]
                    )
                }
                guard let envelope else {
                    return WatchRemoteReplyPayload(
                        values: self.reply(accepted: false)
                    )
                }
                return WatchRemoteReplyPayload(
                    values: self.handle(envelope)
                )
            }
            replyHandler(payload.values)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard let envelope = WatchRemoteCommandEnvelope(message: message) else {
            return
        }
        Task { [weak self] in
            await MainActor.run { [weak self] in
                _ = self?.handle(envelope)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.markNeedsPush(force: true)
        }
    }
}
