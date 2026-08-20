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

        let records = try RecordingLibrary.recordings(root: root)

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
        XCTAssertTrue(try pendingJournals().isEmpty)
    }

    func testLibraryCompletesRenameInterruptedAfterAssetMove() throws {
        let session = try populatedSession(app: "zoom")
        let transaction = RecordingMoveTransaction(
            sourceBasename: session.basename,
            destinationBasename: "2026-07-28-planning")
        let journal = try RecordingFinalizer.persist(transaction, root: root)
        let destinationAsset = root.appendingPathComponent(
            ".assets/2026-07-28-planning",
            isDirectory: true)
        try FileManager.default.moveItem(
            at: session.assetDir,
            to: destinationAsset)

        let recordings = try RecordingLibrary.recordings(root: root)

        XCTAssertEqual(recordings.map(\.basename), ["2026-07-28-planning"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("2026-07-28-planning.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationAsset.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testLibraryCancelsJournalWhenRenameHadNotStarted() throws {
        let session = try populatedSession(app: "zoom")
        let transaction = RecordingMoveTransaction(
            sourceBasename: session.basename,
            destinationBasename: "2026-07-28-planning")
        let journal = try RecordingFinalizer.persist(transaction, root: root)

        let recordings = try RecordingLibrary.recordings(root: root)

        XCTAssertEqual(recordings.map(\.basename), [session.basename])
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.noteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.assetDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testLibrarySurfacesConflictingRenameState() throws {
        let session = try populatedSession(app: "zoom")
        let transaction = RecordingMoveTransaction(
            sourceBasename: session.basename,
            destinationBasename: "2026-07-28-planning")
        let journal = try RecordingFinalizer.persist(transaction, root: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".assets/2026-07-28-planning"),
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try RecordingLibrary.recordings(root: root)) { error in
            guard case RecordingFinalizerError.conflictingTransactionState = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    func testLibraryIsolatesCorruptManifestAndKeepsHealthyRecordings() throws {
        let corrupt = try populatedSession(app: "zoom")
        let healthy = try populatedSession(app: "chime")
        try Data("not json".utf8).write(
            to: corrupt.manifestURL,
            options: .atomic)

        let recordings = try RecordingLibrary.recordings(root: root, limit: nil)

        XCTAssertEqual(recordings.count, 2)
        XCTAssertNotNil(
            recordings.first { $0.basename == corrupt.basename }?.manifestError)
        XCTAssertNil(
            recordings.first { $0.basename == corrupt.basename }?.manifest)
        XCTAssertEqual(
            recordings.first { $0.basename == healthy.basename }?.manifest?.source.appName,
            "chime")
        XCTAssertNil(
            recordings.first { $0.basename == healthy.basename }?.manifestError)
    }

    func testConcurrentFinalizersChooseDistinctDestinations() async throws {
        let first = try populatedSession(app: "zoom")
        let second = try populatedSession(app: "zoom")

        let destinations = try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try RecordingFinalizer.move(first, toTopicSlug: "planning")
            }
            group.addTask {
                try RecordingFinalizer.move(second, toTopicSlug: "planning")
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(
            destinations.map(\.lastPathComponent).sorted(),
            ["2026-07-28-planning-2.md", "2026-07-28-planning.md"])
        XCTAssertTrue(try pendingJournals().isEmpty)
    }

    func testFinalizerRejectsTraversalBasenames() throws {
        let transaction = RecordingMoveTransaction(
            sourceBasename: "..",
            destinationBasename: "2026-07-28-planning")

        XCTAssertThrowsError(try RecordingFinalizer.persist(transaction, root: root)) {
            guard case RecordingFinalizerError.invalidTransaction = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
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

    private func pendingJournals() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(".assets"),
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".meetscribe-move-") }
    }
}
