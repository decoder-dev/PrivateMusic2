import Combine
import Foundation
import WatchConnectivity

/// Mirrors the phone player's latest state to the paired Apple Watch and
/// routes transport commands back to the existing `AudioPlayer`.
@MainActor
final class WatchRemoteCoordinator: NSObject {
    private weak var player: AudioPlayer?
    private let session: WCSession?
    private var cancellables = Set<AnyCancellable>()
    private var lastState: WatchRemoteState?
    private var pendingPushTask: Task<Void, Never>?
    private var pendingForcePush = false
    private var canControlPlayback: @MainActor () -> Bool = { true }
    private var isLiked: @MainActor (Track) -> Bool = { _ in false }
    private var likeCurrent: (@MainActor (Track) async -> Bool)?

    init(player: AudioPlayer) {
        self.player = player
        self.session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    func start() {
        guard let session, let player else { return }
        session.delegate = self
        session.activate()

        Publishers.CombineLatest4(
            player.$queue.removeDuplicates(by: { lhs, rhs in
                lhs.map(\.id) == rhs.map(\.id)
            }),
            player.$currentIndex.removeDuplicates(),
            player.$isPlaying.removeDuplicates(),
            player.$duration
                .map { ($0 * 4).rounded() / 4 }
                .removeDuplicates()
        )
        .sink { [weak self] _, _, _, _ in
            self?.markNeedsPush()
        }
        .store(in: &cancellables)

        // Watch interpolates elapsed from `snapshotDate` + rate. Keep a slow
        // drift correction only — 1 Hz context updates heat the radio link.
        player.progress.$elapsedTime
            .removeDuplicates()
            .throttle(
                for: .seconds(WatchStatePushCoalescingPolicy.driftCorrectionSeconds),
                scheduler: RunLoop.main,
                latest: true
            )
            .sink { [weak self] _ in
                self?.markNeedsPush()
            }
            .store(in: &cancellables)

        player.$isBuffering
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.markNeedsPush()
            }
            .store(in: &cancellables)

        player.$queueSource
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.markNeedsPush()
            }
            .store(in: &cancellables)
    }

    func configureControlGate(
        _ gate: @escaping @MainActor () -> Bool
    ) {
        canControlPlayback = gate
    }

    func configureLibrary(
        isLiked: @escaping @MainActor (Track) -> Bool,
        likeCurrent: @escaping @MainActor (Track) async -> Bool
    ) {
        self.isLiked = isLiked
        self.likeCurrent = likeCurrent
    }

    private func currentState() -> WatchRemoteState {
        guard let player, let track = player.currentTrack else {
            return .empty
        }
        let mixQueue: Bool = {
            if case .mix = player.queueSource { return true }
            return false
        }()
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
            isMixQueue: mixQueue
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

    private func handle(_ message: [String: Any]) -> [String: Any] {
        guard let envelope = WatchRemoteCommandEnvelope(message: message),
              let player,
              canControlPlayback() else {
            return reply(accepted: false)
        }
        guard envelope.isValid(
            at: Date(),
            currentTrackID: player.currentTrack?.id
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
        }
    }
}

enum WatchStatePushCoalescingPolicy {
    /// Progress-only pushes; transport / track changes still flush immediately.
    static let driftCorrectionSeconds: TimeInterval = 20

    static func mergedForce(pending: Bool, incoming: Bool) -> Bool {
        pending || incoming
    }
}

extension WatchRemoteCoordinator: WCSessionDelegate {
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
        Task { @MainActor [weak self] in
            let reply = self?.handle(message) ?? [
                WatchRemoteMessageKey.accepted: false
            ]
            replyHandler(reply)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            _ = self?.handle(message)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.markNeedsPush(force: true)
        }
    }
}
