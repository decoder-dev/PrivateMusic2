import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
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

    @Published private(set) var state: State = .online
    @Published private(set) var transport: Transport = .other
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
