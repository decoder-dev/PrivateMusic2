import Foundation

/// Serializes all offline audio downloads (single tracks, playlist batches and
/// automatic caching) through one queue with a shared concurrency limit.
///
/// A request for a `Track.id` that is already running or waiting awaits the
/// same shared task and receives the same result, so overlapping sources never
/// download the same track twice.
@MainActor
final class DownloadCoordinator {
    static let shared = DownloadCoordinator()
    static let maximumConcurrentDownloads = 3

    private struct RunningEntry {
        let id: String
        let task: Task<Void, Error>
        var subscribers: Set<UUID>
    }

    private struct WaitingEntry {
        let token: UUID
        let id: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var running: [String: RunningEntry] = [:]
    private var waiters: [WaitingEntry] = []
    private var availableSlots = DownloadCoordinator.maximumConcurrentDownloads
    private var queueIsBlocked = false

    var isBusy: Bool {
        !running.isEmpty || !waiters.isEmpty
    }

    func download(
        id: String,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let token = UUID()
        if let task = attachSubscriber(id: id, token: token) {
            try await awaitSharedTask(task, id: id, token: token)
            return
        }
        guard !queueIsBlocked else {
            throw CancellationError()
        }
        if availableSlots > 0 {
            availableSlots -= 1
            try await run(id: id, token: token, operation: operation)
            return
        }

        // No free slot: wait in the shared FIFO queue.
        let receivedSlot = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(
                    WaitingEntry(
                        token: token,
                        id: id,
                        continuation: continuation
                    )
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelWaitingSubscriber(token: token)
            }
        }
        guard receivedSlot, !queueIsBlocked else {
            throw CancellationError()
        }
        if let task = attachSubscriber(id: id, token: token) {
            try await awaitSharedTask(task, id: id, token: token)
            return
        }
        try await run(id: id, token: token, operation: operation)
    }

    /// Blocks new work, cancels every running download and wakes every waiter
    /// with a `CancellationError`. Running entries stay visible until their
    /// tasks actually finish, so `waitUntilIdle()` can still observe them.
    func cancelAll() {
        queueIsBlocked = true
        for entry in running.values {
            entry.task.cancel()
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: false)
        }
        waiters.removeAll()
    }

    func unblockQueue() {
        queueIsBlocked = false
    }

    /// Waits until every running download has finished. Used by the delete-all
    /// flow before files are removed so a cancelled download can never
    /// resurrect a file after deletion.
    func waitUntilIdle() async {
        while let entry = running.first {
            _ = try? await entry.value.task.value
        }
    }

    private func run(
        id: String,
        token: UUID,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let task = Task { @MainActor [weak self] in
            defer {
                self?.finish(id)
            }
            do {
                try await operation()
            } catch {
                throw error
            }
        }
        running[id] = RunningEntry(
            id: id,
            task: task,
            subscribers: [token]
        )
        try await awaitSharedTask(task, id: id, token: token)
    }

    private func attachSubscriber(id: String, token: UUID) -> Task<Void, Error>? {
        guard var entry = running[id] else { return nil }
        entry.subscribers.insert(token)
        running[id] = entry
        return entry.task
    }

    private func awaitSharedTask(
        _ task: Task<Void, Error>,
        id: String,
        token: UUID
    ) async throws {
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.detachSubscriber(
                        id: id,
                        token: token,
                        cancelIfLast: true
                    )
                }
            }
            try Task.checkCancellation()
            detachSubscriber(id: id, token: token, cancelIfLast: false)
        } catch {
            detachSubscriber(id: id, token: token, cancelIfLast: false)
            throw error
        }
    }

    private func detachSubscriber(
        id: String,
        token: UUID,
        cancelIfLast: Bool
    ) {
        guard var entry = running[id] else { return }
        entry.subscribers.remove(token)
        if cancelIfLast, entry.subscribers.isEmpty {
            entry.task.cancel()
        }
        running[id] = entry
    }

    private func cancelWaitingSubscriber(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func finish(_ id: String) {
        running.removeValue(forKey: id)
        availableSlots += 1
        guard !queueIsBlocked else { return }
        while availableSlots > 0, !waiters.isEmpty {
            let next = waiters.removeFirst()
            let duplicates = waiters.filter { $0.id == next.id }
            waiters.removeAll { $0.id == next.id }
            availableSlots -= 1
            next.continuation.resume(returning: true)
            for duplicate in duplicates {
                duplicate.continuation.resume(returning: true)
            }
        }
    }
}
