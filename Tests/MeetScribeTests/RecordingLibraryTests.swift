import XCTest
@testable import MeetScribe

final class RecordingLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testIncludesFailedRecordingWithoutMarkdown() throws {
        let session = RecordingSession(root: root, start: date(2026, 7, 28), appName: "zoom")
        try session.createFolder()
        try Data().write(to: session.micURL)

        let records = RecordingLibrary.recordings(root: root)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].noteURL, session.noteURL)
        XCTAssertFalse(records[0].hasTranscript)
    }

    func testFinalizerAvoidsNoteAndAssetCollisions() throws {
        let session = try populatedSession(app: "zoom")
        let conflictingAssets = root.appendingPathComponent(".assets/2026-07-28-planning")
        try FileManager.default.createDirectory(at: conflictingAssets, withIntermediateDirectories: true)

        let finalNote = try RecordingFinalizer.move(session, toTopicSlug: "planning")

        XCTAssertEqual(finalNote.lastPathComponent, "2026-07-28-planning-2.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".assets/2026-07-28-planning-2").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.assetDir.path))
    }

    func testFinalizedSessionRetainsManifestIdentityAndSource() throws {
        let id = UUID()
        let session = RecordingSession(
            root: root,
            start: date(2026, 7, 28),
            appName: "zoom",
            bundleID: "us.zoom.xos",
            trigger: .meetingPrompt,
            id: id)
        try session.createFolder()
        try Data("note".utf8).write(to: session.noteURL)

        let finalNote = try RecordingFinalizer.move(session, toTopicSlug: "planning")
        let restored = RecordingSession(existingNote: finalNote)

        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.appName, "zoom")
        XCTAssertEqual(restored.sourceBundleID, "us.zoom.xos")
        XCTAssertEqual(restored.trigger, .meetingPrompt)
    }

    func testFinalizerRollsAssetsBackWhenNoteMoveFails() throws {
        let session = RecordingSession(root: root, start: date(2026, 7, 28), appName: "zoom")
        try session.createFolder()

        XCTAssertThrowsError(try RecordingFinalizer.move(session, toTopicSlug: "planning"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.assetDir.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".assets/2026-07-28-planning").path))
    }

    private func populatedSession(app: String) throws -> RecordingSession {
        let session = RecordingSession(root: root, start: date(2026, 7, 28), appName: app)
        try session.createFolder()
        try Data("note".utf8).write(to: session.noteURL)
        return session
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
