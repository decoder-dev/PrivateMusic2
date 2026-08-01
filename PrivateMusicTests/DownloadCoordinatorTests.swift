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
