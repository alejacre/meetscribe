import XCTest
@testable import MeetScribe

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "test.meetscribe")!
        defaults.removePersistentDomain(forName: "test.meetscribe")
    }

    func testDefaults() {
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.outputFolder.path, NSHomeDirectory() + "/Recordings")
        XCTAssertEqual(s.whisperModel, "mlx-community/whisper-large-v3-turbo")
        XCTAssertTrue(s.claudeCleanupEnabled)
        XCTAssertNil(s.autoStopSeconds)
        XCTAssertTrue(s.mlxWhisperPath.hasSuffix("mlx_whisper"))
    }

    func testPersistence() {
        var s = Settings(defaults: defaults)
        s.outputFolder = URL(fileURLWithPath: "/tmp/recs")
        s.claudeCleanupEnabled = false
        s.autoStopSeconds = 30
        let s2 = Settings(defaults: defaults)
        XCTAssertEqual(s2.outputFolder.path, "/tmp/recs")
        XCTAssertFalse(s2.claudeCleanupEnabled)
        XCTAssertEqual(s2.autoStopSeconds, 30)
    }
}
