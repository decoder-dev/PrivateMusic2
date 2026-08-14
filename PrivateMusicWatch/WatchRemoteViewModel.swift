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
                Task { @MainActor in
                    self?.applyReply(context)
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.showCommandFailure()
                }
            }
        )
    }

    private func receive(_ context: [String: Any]) {
        guard let state = WatchRemoteState(context: context) else { return }
        self.state = state
    }

    private func applyReply(_ context: [String: Any]) {
        if let state = WatchRemoteState(context: context) {
            self.state = state
        }
        guard context[WatchRemoteMessageKey.accepted] as? Bool == true else {
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
}

extension WatchRemoteViewModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.isReachable = session.isReachable
            if let state = WatchRemoteState(
                context: session.receivedApplicationContext
            ) {
                self?.state = state
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.receive(applicationContext)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.isReachable = session.isReachable
        }
    }

}
