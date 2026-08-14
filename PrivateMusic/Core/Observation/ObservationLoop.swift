import Observation

/// Re-registers observation after each change so `@Observable` stores
/// do not need Combine `$` publishers.
enum ObservationLoop {
    @MainActor
    final class Token {
        var isCancelled = false
        fileprivate var apply: (() -> Void)?

        fileprivate func tick() {
            guard !isCancelled, let apply else { return }
            withObservationTracking {
                guard !isCancelled else { return }
                apply()
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
        }
    }

    @MainActor
    static func start(
        _ apply: @escaping @MainActor () -> Void
    ) -> Token {
        let token = Token()
        token.apply = apply
        token.tick()
        return token
    }
}
