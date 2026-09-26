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
        XCTAssertTrue(AppLog.shared.isVerbose)
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
        let line = AppLog.formatLine(
            category: .session,
            level: .error,
            message: "refresh failed",
            date: Date(timeIntervalSince1970: 0),
            verbose: false
        )
        XCTAssertTrue(line.contains("[ERROR][session]"))
        XCTAssertTrue(line.contains("refresh failed"))
    }

    func testVerboseFormattedLineIncludesThread() {
        let line = AppLog.formatLine(
            category: .api,
            level: .debug,
            message: "request",
            date: Date(timeIntervalSince1970: 0),
            verbose: true
        )
        XCTAssertTrue(line.contains("[main]"))
    }
}

final class AppLogRedactionTests: XCTestCase {
    func testRedactsAudioAccessKeysIncludingCompoundIdentifiers() {
        let description = AppLogRedaction.describeForm([
            "access_key": "private-key",
            "audios": "1_2_private-key,3_4_another-key",
            "audio_id": "2"
        ])
        XCTAssertFalse(description.contains("private-key"))
        XCTAssertFalse(description.contains("another-key"))
        XCTAssertTrue(description.contains("audio_id=2"))
    }

    func testHistoricalArchiveIsSanitizedWithoutTruncation() {
        let input = "access_key=private-key&audios=1_2_compound-key\n"
            + "HLS fetch encryptionKey: 16 bytes, host example.com, magic aabbccddeeff\n"
            + "HLS fetch mediaSegment: magic 474000\n"
            + String(repeating: "normal log line\n", count: 100)
            + "END"
        let output = String(decoding: AppLogRedaction.redactArchiveData(Data(input.utf8)), as: UTF8.self)
        XCTAssertFalse(output.contains("private-key"))
        XCTAssertFalse(output.contains("compound-key"))
        XCTAssertFalse(output.contains("aabbccddeeff"))
        XCTAssertTrue(output.contains("mediaSegment: magic 474000"))
        XCTAssertTrue(output.hasSuffix("END"))
        XCTAssertEqual(output.split(separator: "\n").count, input.split(separator: "\n").count)
    }

    func testRedactsSensitiveFormKeys() {
        let description = AppLogRedaction.describeForm([
            "access_token": "secret-token-value",
            "v": "5.199",
        ])
        XCTAssertTrue(description.contains("access_token=<redacted>"))
        XCTAssertTrue(description.contains("v=5.199"))
    }
}

final class DeveloperDiagnosticsBuilderTests: XCTestCase {
    func testSnapshotIncludesProvidedFields() {
        let settings = DeveloperSettingsSnapshot(
            appearance: "dark",
            theme: "dark",
            textScale: "system",
            homeStageEnabled: true,
            classicChrome: false,
            preferHighQuality: true,
            crossfadeEnabled: true,
            loudnessNormalization: false,
            equalizerEnabled: false,
            equalizerPreset: "flat",
            mixMoodPreference: "any",
            mixLanguagePreference: "any",
            mixFamiliarityPreference: "any",
            selenaDiversityPreference: "default",
            offlineStorageLimitGB: 5,
            automaticOfflineCacheEnabled: false,
            hapticsEnabled: true,
            advanceOnPlaybackError: true
        )
        let snapshot = DeveloperDiagnosticsBuilder.make(
            networkStatus: "Wi-Fi",
            networkState: "online",
            networkTransport: "wifi",
            sessionActive: true,
            sessionExpiresAt: Date(timeIntervalSince1970: 100),
            sessionCanRefresh: true,
            currentTrackID: "1",
            currentTrackTitle: "Track",
            currentTrackArtist: "Artist",
            isPlaying: true,
            isBuffering: false,
            queueLength: 12,
            queueIndex: 3,
            shuffleEnabled: false,
            fileLogCount: 2,
            totalLogBytes: 128,
            developerMenuUnlocked: true,
            fileLoggingEnabled: true,
            verboseLoggingEnabled: true,
            settings: settings,
            bundle: Bundle(for: DeveloperDiagnosticsBuilderTests.self),
            deviceModel: "iPhone",
            systemVersion: "iOS 26.0",
            localeIdentifier: "en_US",
            capturedAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(snapshot.networkStatus, "Wi-Fi")
        XCTAssertEqual(snapshot.queueLength, 12)
        XCTAssertEqual(snapshot.settings.theme, "dark")
        XCTAssertTrue(snapshot.verboseLoggingEnabled)
    }
}
