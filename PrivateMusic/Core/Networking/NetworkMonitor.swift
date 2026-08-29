import Foundation
import Network

@MainActor
@Observable
final class NetworkMonitor {
    enum State: Equatable {
        case online
        case constrained
        case offline
    }

    enum Transport: Equatable {
        case wifi
        case cellular
        case wired
        case other
        case unavailable
    }

    private(set) var state: State = .online
    private(set) var transport: Transport = .other
    private(set) var revision = 0

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(
        label: "com.dec.privatemusic.network-monitor",
        qos: .utility
    )

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let newState: State
            let newTransport: Transport
            if path.status != .satisfied {
                newState = .offline
                newTransport = .unavailable
            } else if path.isConstrained || path.isExpensive {
                newState = .constrained
                newTransport = Self.transport(for: path)
            } else {
                newState = .online
                newTransport = Self.transport(for: path)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.state != newState
                        || self.transport != newTransport else {
                    return
                }
                self.state = newState
                self.transport = newTransport
                self.revision += 1
                AppLog.shared.info(
                    .network,
                    "Network state=\(newState) transport=\(newTransport) revision=\(self.revision)"
                )
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var isReachable: Bool {
        state != .offline
    }

    /// Collapses `state`/`transport` into the `NetworkCondition` the
    /// player's buffer/retry policy reacts to (see
    /// `NetworkAdaptiveBufferPolicy` in `AudioPlayer.swift`). Read-only:
    /// this does not add to the published state machine above, it only
    /// reads it.
    var condition: NetworkCondition {
        if state == .offline {
            return .offline
        }
        if state == .constrained || transport == .cellular {
            return .degraded
        }
        return .nominal
    }

    private nonisolated static func transport(
        for path: NWPath
    ) -> Transport {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        }
        if path.usesInterfaceType(.cellular) {
            return .cellular
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        }
        return .other
    }
}
