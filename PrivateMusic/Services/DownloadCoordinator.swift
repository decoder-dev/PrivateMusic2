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
    }

    private struct WaitingEntry {
        let id: String
        let operation: @MainActor () async throws -> Void
        let continuation: CheckedContinuation<Void, Never>
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
        if let existing = running[id] {
            try await existing.task.value
            return
        }
        guard !queueIsBlocked else {
            throw CancellationError()
        }
        if availableSlots > 0 {
            availableSlots -= 1
            try await run(id: id, operation: operation)
            return
        }

        // No free slot: wait in the shared FIFO queue.
        await withCheckedContinuation { continuation in
            waiters.append(
                WaitingEntry(
                    id: id,
                    operation: operation,
                    continuation: continuation
                )
            )
        }
        try Task.checkCancellation()
        guard !queueIsBlocked else {
            throw CancellationError()
        }
        if let existing = running[id] {
            try await existing.task.value
            return
        }
        try await run(id: id, operation: operation)
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
            waiter.continuation.resume()
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
        running[id] = RunningEntry(id: id, task: task)
        do {
            try await task.value
        } catch {
            throw error
        }
    }

    private func finish(_ id: String) {
        running.removeValue(forKey: id)
        availableSlots += 1
        guard !queueIsBlocked else { return }
        while availableSlots > 0, !waiters.isEmpty {
            let next = waiters.removeFirst()
            availableSlots -= 1
            next.continuation.resume()
        }
    }
}
