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
    private var canControlPlayback: @MainActor () -> Bool = { true }

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
            player.$duration.removeDuplicates()
        )
        .sink { [weak self] _, _, _, _ in
            self?.pushLatestState()
        }
        .store(in: &cancellables)

        player.$elapsedTime
            .removeDuplicates()
            .throttle(
                for: .seconds(1),
                scheduler: RunLoop.main,
                latest: true
            )
            .sink { [weak self] _ in
                self?.pushLatestState()
            }
            .store(in: &cancellables)

        player.$isBuffering
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.pushLatestState()
            }
            .store(in: &cancellables)
    }

    func configureControlGate(
        _ gate: @escaping @MainActor () -> Bool
    ) {
        canControlPlayback = gate
    }

    private func currentState() -> WatchRemoteState {
        guard let player, let track = player.currentTrack else {
            return .empty
        }
        return WatchRemoteState(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            artworkURL: track.artworkURL,
            isPlaying: player.isPlaying,
            isBuffering: player.isBuffering,
            elapsed: player.elapsedTime,
            duration: player.duration > 0 ? player.duration : track.duration,
            snapshotDate: Date()
        )
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
        case .next:
            player.next()
        case .previous:
            player.previous()
        }
        pushLatestState(force: true)
        return reply(accepted: true)
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
            self?.pushLatestState(force: true)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.pushLatestState(force: true)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor [weak self] in
            replyHandler(self?.handle(message) ?? WatchRemoteState.empty.context)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        // Transport controls are intentionally never queued. Old queued
        // messages from pre-3.26 builds are discarded to avoid stale replay.
    }
}
