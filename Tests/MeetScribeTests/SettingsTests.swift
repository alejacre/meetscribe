import XCTest
@testable import MeetScribe

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "test.meetscribe")!
        defaults.removePersistentDomain(forName: "test.meetscribe")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.meetscribe")
        defaults = nil
    }

    func testDefaults() {
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.outputFolder.path, NSHomeDirectory() + "/Recordings")
        XCTAssertEqual(s.whisperModel, "mlx-community/whisper-large-v3-turbo")
        XCTAssertFalse(s.claudeCleanupEnabled)
        XCTAssertFalse(s.screenPermissionRequested)
        XCTAssertTrue(s.mlxWhisperPath.hasSuffix("mlx_whisper"))
    }

    func testPersistence() {
        var s = Settings(defaults: defaults)
        s.outputFolder = URL(fileURLWithPath: "/tmp/recs")
        s.claudeCleanupEnabled = true
        s.screenPermissionRequested = true
        let s2 = Settings(defaults: defaults)
        XCTAssertEqual(s2.outputFolder.path, "/tmp/recs")
        XCTAssertTrue(s2.claudeCleanupEnabled)
        XCTAssertTrue(s2.screenPermissionRequested)
    }

    func testSetupCompletedDefaultsFalseAndPersists() {
        var s = Settings(defaults: defaults)
        XCTAssertFalse(s.setupCompleted)
        s.setupCompleted = true
        XCTAssertTrue(Settings(defaults: defaults).setupCompleted)
    }
}
