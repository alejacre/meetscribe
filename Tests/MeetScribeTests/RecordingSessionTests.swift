import XCTest
@testable import MeetScribe

final class RecordingSessionTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testNoteNameWithApp() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp/recs"),
                                 start: date(2026, 7, 13, 15, 30), appName: "zoom")
        XCTAssertEqual(s.noteURL.path, "/tmp/recs/2026-07-13-zoom.md")
    }

    func testNoteNameManual() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp/recs"),
                                 start: date(2026, 7, 13, 9, 5), appName: nil)
        XCTAssertEqual(s.noteURL.lastPathComponent, "2026-07-13-manual.md")
    }

    func testAssetURLs() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp/recs"),
                                 start: date(2026, 7, 13, 9, 5), appName: "slack")
        // Media + raw JSON live in a hidden per-note sidecar dir.
        XCTAssertEqual(s.assetDir.path, "/tmp/recs/.assets/2026-07-13-slack")
        XCTAssertEqual(s.micURL.path, "/tmp/recs/.assets/2026-07-13-slack/mic.m4a")
        XCTAssertEqual(s.systemURL.lastPathComponent, "system.m4a")
        XCTAssertEqual(s.mixURL.lastPathComponent, "audio.m4a")
        XCTAssertEqual(s.transcriptJSON.lastPathComponent, "transcript.json")
        // The transcript IS the note itself.
        XCTAssertEqual(s.transcriptMD, s.noteURL)
    }

    func testBasenameAndDatePart() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp"),
                                 start: date(2026, 7, 13, 9, 5), appName: "zoom")
        XCTAssertEqual(s.basename, "2026-07-13-zoom")
        XCTAssertEqual(s.datePart, "2026-07-13")
    }

    func testAppNameSanitized() {
        let s = RecordingSession(root: URL(fileURLWithPath: "/tmp"), start: Date(), appName: "Microsoft Teams")
        XCTAssertTrue(s.basename.hasSuffix("-microsoft-teams"))
    }

    func testNoteCollisionGetsSuffix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = date(2026, 7, 13, 15, 30)

        let s1 = RecordingSession(root: root, start: start, appName: "zoom")
        XCTAssertEqual(s1.noteURL.lastPathComponent, "2026-07-13-zoom.md")
        // The note file itself is what the collision probe checks.
        FileManager.default.createFile(atPath: s1.noteURL.path, contents: nil)

        let s2 = RecordingSession(root: root, start: start, appName: "zoom")
        XCTAssertEqual(s2.noteURL.lastPathComponent, "2026-07-13-zoom-2.md")
        FileManager.default.createFile(atPath: s2.noteURL.path, contents: nil)

        let s3 = RecordingSession(root: root, start: start, appName: "zoom")
        XCTAssertEqual(s3.noteURL.lastPathComponent, "2026-07-13-zoom-3.md")
    }

    func testOrphanedAssetDirForcesSuffix() throws {
        // A recording whose transcription failed leaves .assets/<base>/ (audio) but never
        // writes the <base>.md. The next same-day recording must NOT reuse that dir, or it
        // overwrites the first recording's mic/system audio. Probe must check the asset dir,
        // not just the note file.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = date(2026, 7, 13, 15, 30)

        let s1 = RecordingSession(root: root, start: start, appName: "zoom")
        // Only the asset dir exists (transcription failed before the .md was written).
        try FileManager.default.createDirectory(at: s1.assetDir, withIntermediateDirectories: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s1.noteURL.path))

        let s2 = RecordingSession(root: root, start: start, appName: "zoom")
        XCTAssertEqual(s2.noteURL.lastPathComponent, "2026-07-13-zoom-2.md")
        XCTAssertNotEqual(s2.assetDir.path, s1.assetDir.path)
    }

    func testExistingNoteInit() {
        let url = URL(fileURLWithPath: "/tmp/recs/2026-07-13-q2-review.md")
        let s = RecordingSession(existingNote: url)
        XCTAssertEqual(s.noteURL, url)
        XCTAssertEqual(s.basename, "2026-07-13-q2-review")
        XCTAssertEqual(s.micURL.path, "/tmp/recs/.assets/2026-07-13-q2-review/mic.m4a")
        XCTAssertEqual(RecordingSession.headerDateFormatter.string(from: s.start), "2026-07-13")
    }

    func testCreatesPrivateAssetDirectoryAndFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(root: root, start: date(2026, 7, 13, 9, 5), appName: nil)
        try session.createFolder()
        try Data("private".utf8).write(to: session.transcriptJSON)
        try session.secureFile(session.transcriptJSON)

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: session.assetDir.path)[.posixPermissions] as? NSNumber)
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: session.transcriptJSON.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }

    func testCreateFolderPersistsPrivateManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let start = date(2026, 8, 20, 10, 30)
        let session = RecordingSession(
            root: root,
            start: start,
            appName: "teams",
            bundleID: "com.microsoft.teams2",
            trigger: .meetingAutomatic,
            id: id)

        try session.createFolder()

        let manifest = try RecordingManifestStore.load(from: session.manifestURL)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: session.manifestURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(manifest.schemaVersion, RecordingManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.id, id)
        XCTAssertEqual(manifest.startedAt, start)
        XCTAssertEqual(manifest.source.appName, "teams")
        XCTAssertEqual(manifest.source.bundleID, "com.microsoft.teams2")
        XCTAssertEqual(manifest.source.trigger, .meetingAutomatic)
        XCTAssertEqual(manifest.lifecycle, .recording)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    func testRejectsUnsupportedManifestSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-manifest-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(root: root, start: Date(), appName: nil)
        try session.createFolder()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: session.manifestURL))
                as? [String: Any])
        json["schemaVersion"] = RecordingManifest.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(
            to: session.manifestURL,
            options: .atomic)

        XCTAssertThrowsError(try RecordingManifestStore.load(from: session.manifestURL)) { error in
            guard case RecordingManifestError.unsupportedSchemaVersion(
                RecordingManifest.currentSchemaVersion + 1
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
