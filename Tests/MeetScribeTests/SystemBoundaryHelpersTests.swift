import XCTest
@testable import MeetScribe

final class SystemBoundaryHelpersTests: XCTestCase {
    func testNotifierResolvesOnlySafeNoteReferences() {
        let output = URL(fileURLWithPath: "/tmp/recordings")

        XCTAssertEqual(
            Notifier.noteURL(
                from: ["notePath": "/tmp/recordings/meeting.md"],
                outputFolder: output)?.path,
            "/tmp/recordings/meeting.md")
        XCTAssertEqual(
            Notifier.noteURL(
                from: ["recording": "2026-08-20-planning"],
                outputFolder: output)?.path,
            "/tmp/recordings/2026-08-20-planning.md")
        XCTAssertNil(Notifier.noteURL(
            from: ["notePath": "/tmp/recordings/meeting.txt"],
            outputFolder: output))
        XCTAssertNil(Notifier.noteURL(
            from: ["recording": "../outside"],
            outputFolder: output))
        XCTAssertNil(Notifier.noteURL(
            from: ["recording": "folder/meeting"],
            outputFolder: output))
    }

    func testPermissionDeepLinksAllowOnlySupportedPanes() {
        XCTAssertEqual(
            Permissions.privacyPaneURL("Privacy_ScreenCapture")?.scheme,
            "x-apple.systempreferences")
        XCTAssertNotNil(Permissions.privacyPaneURL("Privacy_Microphone"))
        XCTAssertNil(Permissions.privacyPaneURL("Privacy_AllFiles"))
        XCTAssertNil(Permissions.privacyPaneURL("bad\nanchor"))
    }

    func testNotifierMapsRecordingActionsToAudioModes() {
        XCTAssertEqual(
            Notifier.audioMode(
                forRecordActionIdentifier: Notifier.recordWithMicrophoneAction),
            .microphoneAndSystem)
        XCTAssertEqual(
            Notifier.audioMode(
                forRecordActionIdentifier: Notifier.recordSystemOnlyAction),
            .systemOnly)
        XCTAssertEqual(
            Notifier.audioMode(forRecordActionIdentifier: "RECORD"),
            .microphoneAndSystem)
        XCTAssertNil(
            Notifier.audioMode(forRecordActionIdentifier: "UNKNOWN"))
    }
}
