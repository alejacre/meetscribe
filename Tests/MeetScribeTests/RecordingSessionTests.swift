import XCTest
@testable import MeetScribe

final class RecordingSessionTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testFolderNameWithApp() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp/recs"),
                                 start: date(2026, 7, 13, 15, 30), appName: "zoom")
        XCTAssertEqual(s.folder.path, "/tmp/recs/2026-07-13_15-30_zoom")
    }

    func testFolderNameManual() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp/recs"),
                                 start: date(2026, 7, 13, 9, 5), appName: nil)
        XCTAssertEqual(s.folder.lastPathComponent, "2026-07-13_09-05_manual")
    }

    func testFileURLs() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp/recs"), start: Date(), appName: "slack")
        XCTAssertEqual(s.micURL.lastPathComponent, "mic.m4a")
        XCTAssertEqual(s.systemURL.lastPathComponent, "system.m4a")
        XCTAssertEqual(s.mixURL.lastPathComponent, "audio.m4a")
        XCTAssertEqual(s.transcriptMD.lastPathComponent, "transcript.md")
        XCTAssertEqual(s.transcriptJSON.lastPathComponent, "transcript.json")
    }

    func testAppNameSanitized() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp"), start: Date(), appName: "Microsoft Teams")
        XCTAssertTrue(s.folder.lastPathComponent.hasSuffix("_microsoft-teams"))
    }

    func testFolderCollisionGetsSuffix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = date(2026, 7, 13, 15, 30)

        let s1 = RecordingSession(root: root, start: start, appName: "zoom")
        XCTAssertEqual(s1.folder.lastPathComponent, "2026-07-13_15-30_zoom")
        try s1.createFolder()

        let s2 = RecordingSession(root: root, start: start, appName: "zoom")
        XCTAssertEqual(s2.folder.lastPathComponent, "2026-07-13_15-30_zoom-2")
        try s2.createFolder()

        let s3 = RecordingSession(root: root, start: start, appName: "zoom")
        XCTAssertEqual(s3.folder.lastPathComponent, "2026-07-13_15-30_zoom-3")
    }

    func testExistingFolderInit() {
        let url = URL(fileURLWithPath: "/tmp/recs/2026-07-13_15-30_zoom")
        let s = RecordingSession(existingFolder: url, start: Date())
        XCTAssertEqual(s.folder, url)
        XCTAssertEqual(s.micURL.lastPathComponent, "mic.m4a")
    }
}
