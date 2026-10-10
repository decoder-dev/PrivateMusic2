import XCTest
@testable import PrivateMusic

final class PlaybackIntentsTests: XCTestCase {
    func testShortcutsStayWithinTheSystemLimit() {
        let count = PrivateMusicShortcuts.appShortcuts.count
        XCTAssertEqual(count, 4)
        XCTAssertLessThanOrEqual(count, 10)
    }

    func testEveryIntentTitleExistsInBothLanguages() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PrivateMusic/Resources")
        for language in ["en", "ru"] {
            let url = root.appendingPathComponent("\(language).lproj/Localizable.strings")
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in [
                "intent.play_my_mix", "intent.toggle_playback",
                "intent.next_track", "intent.previous_track",
                "intent.app_not_ready", "intent.sign_in_required"
            ] {
                XCTAssertTrue(text.contains("\"\(key)\""), "\(language): \(key)")
            }
        }
    }
}
