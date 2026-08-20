import XCTest
@testable import MeetScribe

@MainActor
final class RecordingsViewModelTests: XCTestCase {
    nonisolated(unsafe) private var roots: [URL] = []

    override func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    func testReloadSelectAndSearchTranscriptContent() async throws {
        let root = try temporaryDirectory("model-search")
        let first = try recording(
            root: root,
            date: date(2026, 8, 20),
            app: "zoom",
            title: "product-review",
            transcript: "The signed application uses real screenshots.")
        _ = try recording(
            root: root,
            date: date(2026, 8, 18),
            app: "chime",
            title: "release-planning",
            transcript: "The coverage gate remains enabled.")
        let model = RecordingsViewModel(root: root)

        model.reload(selecting: first.noteURL)
        await waitUntilLoaded(model)

        XCTAssertEqual(model.recordings.count, 2)
        XCTAssertEqual(model.selectedRecording?.noteURL, first.noteURL)
        XCTAssertEqual(model.documents.count, 2)

        model.query = "coverage gate"
        await waitUntilSearchFinished(model)
        XCTAssertEqual(
            model.visibleRecordings.map(\.basename),
            ["2026-08-18-release-planning"])

        model.query = "product-review"
        await waitUntilSearchFinished(model)
        XCTAssertEqual(model.visibleRecordings.map(\.basename), [first.basename])

        model.query = ""
        XCTAssertEqual(model.visibleRecordings.count, 2)
    }

    func testReloadPreservesSelectionAndSelectsRequestedRecording() async throws {
        let root = try temporaryDirectory("model-selection")
        let first = try recording(
            root: root,
            date: date(2026, 8, 20),
            app: "zoom",
            title: "first",
            transcript: "First transcript.")
        let second = try recording(
            root: root,
            date: date(2026, 8, 19),
            app: "chime",
            title: "second",
            transcript: "Second transcript.")
        let model = RecordingsViewModel(root: root)

        model.reload()
        await waitUntilLoaded(model)
        model.select(noteURL: second.noteURL)
        XCTAssertEqual(model.selectedRecording?.noteURL, second.noteURL)

        model.reload()
        await waitUntilLoaded(model)
        XCTAssertEqual(model.selectedRecording?.noteURL, second.noteURL)

        model.select(noteURL: first.noteURL)
        XCTAssertEqual(model.selectedRecording?.noteURL, first.noteURL)
    }

    func testReloadKeepsHealthyRecordingsWhenOneManifestIsCorrupt() async throws {
        let root = try temporaryDirectory("model-error")
        let corrupt = try recording(
            root: root,
            date: date(2026, 8, 20),
            app: "zoom",
            title: "broken",
            transcript: "Transcript.")
        let healthy = try recording(
            root: root,
            date: date(2026, 8, 19),
            app: "chime",
            title: "healthy",
            transcript: "Healthy transcript.")
        try Data("not json".utf8).write(to: corrupt.manifestURL, options: .atomic)
        let model = RecordingsViewModel(root: root)

        model.reload()
        await waitUntilLoaded(model)

        XCTAssertEqual(model.recordings.count, 2)
        XCTAssertEqual(model.documents.count, 2)
        XCTAssertNil(model.error)
        XCTAssertNotNil(
            model.recordings.first { $0.noteURL == corrupt.noteURL }?.manifestError)
        XCTAssertNil(
            model.recordings.first { $0.noteURL == healthy.noteURL }?.manifestError)
    }

    func testReloadCanSwitchOutputFoldersWithoutRecreatingModel() async throws {
        let firstRoot = try temporaryDirectory("model-first-root")
        let secondRoot = try temporaryDirectory("model-second-root")
        _ = try recording(
            root: firstRoot,
            date: date(2026, 8, 20),
            app: "zoom",
            title: "first-root",
            transcript: "First root transcript.")
        let second = try recording(
            root: secondRoot,
            date: date(2026, 8, 19),
            app: "chime",
            title: "second-root",
            transcript: "Second root transcript.")
        let model = RecordingsViewModel(root: firstRoot)

        model.reload()
        await waitUntilLoaded(model)
        XCTAssertEqual(model.recordings.count, 1)

        model.reload(root: secondRoot)
        await waitUntilLoaded(model)

        XCTAssertEqual(model.root, secondRoot.standardizedFileURL)
        XCTAssertEqual(model.recordings.map(\.noteURL), [second.noteURL])
    }

    func testReloadReportsActualLibraryFailure() async throws {
        let root = try temporaryDirectory("model-library-error")
        try Data("not a directory".utf8).write(
            to: root.appendingPathComponent(".assets"),
            options: .atomic)
        let model = RecordingsViewModel(root: root)

        model.reload()
        await waitUntilLoaded(model)

        XCTAssertTrue(model.recordings.isEmpty)
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertNil(model.selectedRecording)
        XCTAssertNotNil(model.error)
    }

    func testLatestSearchWinsAndWhitespaceIsNormalized() async throws {
        let root = try temporaryDirectory("model-search-cancellation")
        _ = try recording(
            root: root,
            date: date(2026, 8, 20),
            app: "zoom",
            title: "first",
            transcript: "Old search phrase.")
        let second = try recording(
            root: root,
            date: date(2026, 8, 19),
            app: "chime",
            title: "second",
            transcript: "Current search phrase.")
        let model = RecordingsViewModel(root: root)
        model.reload()
        await waitUntilLoaded(model)

        model.query = "old search"
        model.query = "  current search  "
        await waitUntilSearchFinished(model)

        XCTAssertEqual(model.visibleRecordings.map(\.noteURL), [second.noteURL])
    }

    private func recording(
        root: URL,
        date: Date,
        app: String,
        title: String,
        transcript: String
    ) throws -> RecordingSession {
        let initial = RecordingSession(root: root, start: date, appName: app)
        try initial.createFolder()
        try Data("# Transcript\n".utf8).write(to: initial.noteURL)
        let finalNote = try RecordingFinalizer.move(initial, toTopicSlug: title)
        let session = RecordingSession(existingNote: finalNote)
        try """
        ---
        date: \(RecordingSession.headerDateFormatter.string(from: date))
        tags: [meeting, transcript]
        ---

        ## Summary
        A searchable summary.

        ## Transcript
        [00:00:01] **Me:** \(transcript)

        <!-- meetscribe: app=\(app), duration=00:10:00, model=test, cleaned=false, processor=none -->
        """.write(to: session.noteURL, atomically: true, encoding: .utf8)
        return session
    }

    private func waitUntilLoaded(_ model: RecordingsViewModel) async {
        for _ in 0..<100 where model.isLoading {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isLoading)
    }

    private func waitUntilSearchFinished(_ model: RecordingsViewModel) async {
        for _ in 0..<100 where model.isSearching {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isSearching)
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meetscribe-recordings-view-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
