import Foundation
import WatchConnectivity

@MainActor
final class WatchRemoteViewModel: NSObject, ObservableObject {
    @Published private(set) var state: WatchRemoteState = .empty
    @Published private(set) var isReachable = false

    private let session: WCSession?

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

    func send(_ command: WatchRemoteCommand) {
        guard let session else { return }
        let message = [WatchRemoteMessageKey.command: command.rawValue]
        if session.isReachable {
            session.sendMessage(
                message,
                replyHandler: { [weak self] context in
                    guard let state = WatchRemoteState(context: context) else {
                        return
                    }
                    Task { @MainActor in
                        self?.state = state
                    }
                },
                errorHandler: nil
            )
        } else {
            session.transferUserInfo(message)
        }
    }

    private func receive(_ context: [String: Any]) {
        guard let state = WatchRemoteState(context: context) else { return }
        self.state = state
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

    // Required when a build tool type-checks the embedded target against an
    // iOS SDK; harmless on watchOS and supports multi-watch reactivation.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
