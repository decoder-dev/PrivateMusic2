import Observation

/// Re-registers observation after each change so `@Observable` stores
/// do not need Combine `$` publishers.
enum ObservationLoop {
    @MainActor
    final class Token {
        var isCancelled = false
    }

    @MainActor
    static func start(
        _ apply: @escaping @MainActor () -> Void
    ) -> Token {
        let token = Token()
        func tick() {
            guard !token.isCancelled else { return }
            withObservationTracking {
                guard !token.isCancelled else { return }
                apply()
            } onChange: {
                Task { @MainActor in
                    tick()
                }
            }
        }
        tick()
        return token
    }
}
