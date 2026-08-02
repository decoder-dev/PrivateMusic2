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
            player.$queue,
            player.$currentIndex,
            player.$isPlaying,
            player.$duration
        )
        .sink { [weak self] _, _, _, _ in
            self?.pushLatestState()
        }
        .store(in: &cancellables)

        player.$elapsedTime
            .throttle(
                for: .seconds(1),
                scheduler: RunLoop.main,
                latest: true
            )
            .sink { [weak self] _ in
                self?.pushLatestState()
            }
            .store(in: &cancellables)
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
            elapsed: player.elapsedTime,
            duration: player.duration > 0 ? player.duration : track.duration
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

    private func handle(_ message: [String: Any]) -> [String: Any] {
        guard let raw = message[WatchRemoteMessageKey.command] as? String,
              let command = WatchRemoteCommand(rawValue: raw),
              let player else {
            return currentState().context
        }
        switch command {
        case .togglePlayPause:
            player.playPause()
        case .next:
            player.next()
        case .previous:
            player.previous()
        }
        pushLatestState(force: true)
        return currentState().context
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
        Task { @MainActor [weak self] in
            _ = self?.handle(userInfo)
        }
    }
}
