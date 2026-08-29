import XCTest
@testable import PrivateMusic

final class DeveloperUnlockPolicyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DeveloperFeature.resetForTesting()
    }

    func testUnlocksOnSeventhTap() {
        var taps = 0
        var unlocked = false
        for _ in 0 ..< 6 {
            let step = DeveloperUnlockPolicy.nextTapCount(taps)
            taps = step.taps
            unlocked = step.unlocked
            XCTAssertFalse(unlocked)
        }
        let final = DeveloperUnlockPolicy.nextTapCount(taps)
        XCTAssertEqual(final.taps, 7)
        XCTAssertTrue(final.unlocked)
    }

    func testRegisterVersionTapUnlocksMenuAndPersists() {
        for index in 0 ..< 6 {
            XCTAssertFalse(DeveloperFeature.registerVersionTap())
            XCTAssertFalse(DeveloperFeature.isUnlocked)
            XCTAssertEqual(DeveloperFeature.versionTapCount, index + 1)
        }
        XCTAssertTrue(DeveloperFeature.registerVersionTap())
        XCTAssertTrue(DeveloperFeature.isUnlocked)
        XCTAssertTrue(AppLog.shared.isFileLoggingEnabled)
    }
}

final class ZipArchiveWriterTests: XCTestCase {
    func testArchiveContainsLocalFileHeaderAndCentralDirectory() throws {
        let entries = [
            ZipArchiveWriter.Entry(
                path: "manifest.json",
                data: Data("{\"ok\":true}".utf8)
            ),
            ZipArchiveWriter.Entry(
                path: "logs/PrivateMusic.log",
                data: Data("hello\n".utf8)
            ),
        ]
        let zip = try ZipArchiveWriter.archive(entries: entries)
        XCTAssertGreaterThan(zip.count, 64)
        XCTAssertEqual(zip.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
        XCTAssertTrue(
            zip.range(of: Data("manifest.json".utf8)) != nil
        )
        XCTAssertTrue(
            zip.suffix(22).starts(with: Data([0x50, 0x4b, 0x05, 0x06]))
        )
    }

    func testEmptyArchiveFails() {
        XCTAssertThrowsError(try ZipArchiveWriter.archive(entries: [])) { error in
            XCTAssertEqual(error as? LogArchiveError, .emptyArchive)
        }
    }
}

final class AppLogFormattingTests: XCTestCase {
    func testFormattedLineIncludesCategoryAndLevel() {
        let date = Date(timeIntervalSince1970: 0)
        let line = AppLog.formatLine(
            category: .session,
            level: .error,
            message: "refresh failed"
        )
        XCTAssertTrue(line.contains("[ERROR][session]"))
        XCTAssertTrue(line.contains("refresh failed"))
        _ = date
    }
}

final class DeveloperDiagnosticsBuilderTests: XCTestCase {
    func testSnapshotIncludesProvidedFields() {
        let snapshot = DeveloperDiagnosticsBuilder.make(
            networkStatus: "Wi-Fi",
            sessionActive: true,
            sessionExpiresAt: Date(timeIntervalSince1970: 100),
            currentTrackTitle: "Track",
            isPlaying: true,
            fileLogCount: 2,
            totalLogBytes: 128,
            developerMenuUnlocked: true,
            fileLoggingEnabled: true,
            bundle: Bundle(for: DeveloperDiagnosticsBuilderTests.self),
            deviceModel: "iPhone",
            systemVersion: "iOS 26.0",
            localeIdentifier: "en_US",
            capturedAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(snapshot.networkStatus, "Wi-Fi")
        XCTAssertEqual(snapshot.currentTrackTitle, "Track")
        XCTAssertEqual(snapshot.fileLogCount, 2)
        XCTAssertTrue(snapshot.developerMenuUnlocked)
    }
}
