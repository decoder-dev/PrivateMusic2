import XCTest
@testable import PrivateMusic

@MainActor
final class DownloadCoordinatorTests: XCTestCase {
    func testConcurrentDownloadsOfSameIDRunOnce() async throws {
        let coordinator = DownloadCoordinator()
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { @MainActor in
                    try await coordinator.download(id: "shared") {
                        counter.increment()
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testConcurrencyIsCappedAtThree() async throws {
        let coordinator = DownloadCoordinator()
        let peak = PeakTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { @MainActor in
                    try await coordinator.download(id: "task-\(index)") {
                        peak.enter()
                        try await Task.sleep(for: .milliseconds(80))
                        peak.exit()
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertLessThanOrEqual(peak.maximum, 3)
        XCTAssertGreaterThan(peak.maximum, 1)
    }

    func testWaitUntilIdleWaitsForRunningDownloads() async throws {
        let coordinator = DownloadCoordinator()
        let started = expectation(description: "download started")
        started.assertForOverFulfill = false
        let download = Task { @MainActor in
            try await coordinator.download(id: "slow") {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let began = Date()
        await coordinator.waitUntilIdle()
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(began),
            0.2
        )
        _ = try await download.value
    }

    func testCancelAllCancelsRunningWorkAndBlocksNewDownloads() async throws {
        let coordinator = DownloadCoordinator()
        let started = expectation(description: "download started")
        started.assertForOverFulfill = false
        let download = Task { @MainActor in
            try await coordinator.download(id: "slow") {
                started.fulfill()
                try await Task.sleep(for: .seconds(5))
            }
        }
        await fulfillment(of: [started], timeout: 1)

        coordinator.cancelAll()
        do {
            _ = try await download.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
        }

        do {
            _ = try await coordinator.download(id: "new") {}
            XCTFail("Expected CancellationError while queue is blocked")
        } catch is CancellationError {
        }

        coordinator.unblockQueue()
        try await coordinator.download(id: "new") {}
    }

    func testCancellingOnlySubscriberCancelsUnderlyingOperation() async {
        let coordinator = DownloadCoordinator()
        let started = expectation(description: "operation started")
        let stopped = expectation(description: "operation stopped")
        let download = Task { @MainActor in
            try await coordinator.download(id: "cancel-me") {
                started.fulfill()
                defer { stopped.fulfill() }
                try await Task.sleep(for: .seconds(5))
            }
        }
        await fulfillment(of: [started], timeout: 1)
        download.cancel()

        do {
            try await download.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testCancellingOneSubscriberDoesNotCancelOtherSubscriber() async throws {
        let coordinator = DownloadCoordinator()
        let started = expectation(description: "shared operation started")
        let counter = Counter()
        let first = Task { @MainActor in
            try await coordinator.download(id: "shared-cancel") {
                counter.increment()
                started.fulfill()
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let second = Task { @MainActor in
            try await coordinator.download(id: "shared-cancel") {
                XCTFail("Duplicate operation must not run")
            }
        }
        await Task.yield()
        first.cancel()

        do {
            try await first.value
            XCTFail("Cancelled subscriber must receive CancellationError")
        } catch is CancellationError {
        }
        try await second.value
        XCTAssertEqual(counter.value, 1)
    }

    func testQueuedDuplicatesDoNotConsumeConcurrencySlots() async throws {
        let coordinator = DownloadCoordinator()
        let blockersStarted = expectation(description: "three blockers started")
        blockersStarted.expectedFulfillmentCount = 3
        let blockers = (0..<3).map { index in
            Task { @MainActor in
                try await coordinator.download(id: "blocker-\(index)") {
                    blockersStarted.fulfill()
                    try await Task.sleep(for: .milliseconds(180))
                }
            }
        }
        await fulfillment(of: [blockersStarted], timeout: 1)

        let duplicateCounter = Counter()
        let duplicates = (0..<5).map { _ in
            Task { @MainActor in
                try await coordinator.download(id: "queued-duplicate") {
                    duplicateCounter.increment()
                    try await Task.sleep(for: .milliseconds(40))
                }
            }
        }
        for task in blockers + duplicates {
            try await task.value
        }
        XCTAssertEqual(duplicateCounter.value, 1)

        let restoredPeak = PeakTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask { @MainActor in
                    try await coordinator.download(id: "after-\(index)") {
                        restoredPeak.enter()
                        try await Task.sleep(for: .milliseconds(80))
                        restoredPeak.exit()
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(restoredPeak.maximum, 3)
    }
}

private final class Counter: @unchecked Sendable {
    private var _value = 0
    var value: Int {
        lock.withLock { _value }
    }
    func increment() {
        lock.withLock { _value += 1 }
    }
    private let lock = NSLock()
}

private final class PeakTracker: @unchecked Sendable {
    private var active = 0
    private var peak = 0
    var maximum: Int {
        lock.withLock { peak }
    }
    func enter() {
        lock.withLock {
            active += 1
            peak = max(peak, active)
        }
    }
    func exit() {
        lock.withLock { active -= 1 }
    }
    private let lock = NSLock()
}
