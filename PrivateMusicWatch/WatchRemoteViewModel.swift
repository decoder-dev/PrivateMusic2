import Foundation
import WatchConnectivity
import WatchKit

@MainActor
@Observable
final class WatchRemoteViewModel: NSObject {
    private(set) var state: WatchRemoteState = .empty
    private(set) var isReachable = false
    private(set) var commandFailed = false

    private let session: WCSession?
    private var feedbackTask: Task<Void, Never>?

    override init() {
        self.session = WCSession.isSupported() ? .default : nil
        super.init()
        session?.delegate = self
        session?.activate()
        if let context = session?.receivedApplicationContext,
           let state = WatchRemoteState(context: context) {
            self.state = state
        }
        isReachable = session?.isReachable ?? false
    }

    func send(_ command: WatchRemoteCommand, trackID: String? = nil) {
        guard let session, session.isReachable else {
            showCommandFailure()
            return
        }
        let envelope = WatchRemoteCommandEnvelope(
            command: command,
            trackID: command == .playQueueItem
                ? trackID
                : (trackID ?? state.trackID)
        )
        session.sendMessage(
            envelope.message,
            replyHandler: { [weak self] context in
                let parsed = Self.parseReply(context)
                Task { @MainActor in
                    self?.applyReply(
                        state: parsed.state,
                        accepted: parsed.accepted
                    )
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.showCommandFailure()
                }
            }
        )
    }

    private func receive(_ state: WatchRemoteState) {
        self.state = state
    }

    private func applyReply(state: WatchRemoteState?, accepted: Bool?) {
        if let state {
            self.state = state
        }
        guard accepted == true else {
            showCommandFailure()
            return
        }
        commandFailed = false
    }

    private func showCommandFailure() {
        commandFailed = true
        WKInterfaceDevice.current().play(.failure)
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.commandFailed = false
        }
    }
    private static nonisolated func parseReply(
        _ context: [String: Any]
    ) -> (state: WatchRemoteState?, accepted: Bool?) {
        (
            WatchRemoteState(context: context),
            context[WatchRemoteMessageKey.accepted] as? Bool
        )
    }
}

extension WatchRemoteViewModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        let state = WatchRemoteState(context: session.receivedApplicationContext)
        Task { @MainActor [weak self] in
            self?.isReachable = reachable
            if let state {
                self?.receive(state)
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let state = WatchRemoteState(context: applicationContext) else {
            return
        }
        Task { @MainActor [weak self] in
            self?.receive(state)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isReachable = reachable
        }
    }

}
