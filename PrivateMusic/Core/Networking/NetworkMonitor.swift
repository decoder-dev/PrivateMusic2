import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    enum State: Equatable {
        case online
        case constrained
        case offline
    }

    @Published private(set) var state: State = .online
    @Published private(set) var revision = 0

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(
        label: "com.dec.privatemusic.network-monitor",
        qos: .utility
    )

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let newState: State
            if path.status != .satisfied {
                newState = .offline
            } else if path.isConstrained || path.isExpensive {
                newState = .constrained
            } else {
                newState = .online
            }
            Task { @MainActor [weak self] in
                guard let self, self.state != newState else { return }
                self.state = newState
                self.revision += 1
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
}
