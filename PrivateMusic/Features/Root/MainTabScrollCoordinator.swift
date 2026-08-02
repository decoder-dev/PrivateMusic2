import Foundation

enum MainTabScrollDestination: Hashable {
    case home
    case library
    case search
    case profile
}

struct MainTabScrollRequest: Equatable {
    let destination: MainTabScrollDestination
    let id: UUID
}

enum TabReselectionPolicy {
    static func isReselection<Value: Equatable>(
        current: Value,
        tapped: Value
    ) -> Bool {
        current == tapped
    }
}

@MainActor
final class MainTabScrollCoordinator: ObservableObject {
    @Published private(set) var request: MainTabScrollRequest?

    func scrollToTop(_ destination: MainTabScrollDestination) {
        request = MainTabScrollRequest(
            destination: destination,
            id: UUID()
        )
    }
}
