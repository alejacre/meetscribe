import XCTest
@testable import MeetScribe

final class TranscriptSearchTests: XCTestCase {
    func testSearchFindsCaseInsensitiveMatchesAndSkipsUnmanagedMarkdown() async throws {
        let root = try temporaryDirectory("search")
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = RecordingSession(
            root: root,
            start: Date(),
            appName: "zoom")
        try managed.createFolder()
        try Data("Alpha line\nsecond line\n".utf8).write(to: managed.noteURL)
        try Data("Alpha unmanaged\n".utf8).write(
            to: root.appendingPathComponent("personal-note.md"))

        let hits = await TranscriptSearch.search("alpha", root: root)

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(
            hits.first?.file.standardizedFileURL,
            managed.noteURL.standardizedFileURL)
        XCTAssertEqual(hits.first?.line, "Alpha line")
    }

    func testSearchTrimsBlankQueriesAndCapsResults() async throws {
        let root = try temporaryDirectory("search-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = RecordingSession(
            root: root,
            start: Date(),
            appName: "zoom")
        try managed.createFolder()
        let lines = (0..<150).map { "match \($0)" }.joined(separator: "\n")
        try Data(lines.utf8).write(to: managed.noteURL)

        let blank = await TranscriptSearch.search("  \n ", root: root)
        let capped = await TranscriptSearch.search("match", root: root)

        XCTAssertTrue(blank.isEmpty)
        XCTAssertEqual(capped.count, 100)
    }

    func testCancelledSearchReturnsNoPartialResults() async throws {
        let root = try temporaryDirectory("search-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 {
            let session = RecordingSession(
                root: root,
                start: Date(),
                appName: "meeting-\(index)")
            try session.createFolder()
            let body = String(repeating: "match payload\n", count: 2_000)
            try Data(body.utf8).write(to: session.noteURL)
        }

        let task = Task {
            await TranscriptSearch.search("match", root: root)
        }
        task.cancel()

        let result = await task.value
        XCTAssertTrue(result.isEmpty)
    }

    func testIndexReusesUnchangedFilesAndRefreshesModifiedNotes() async throws {
        let root = try temporaryDirectory("search-index")
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = RecordingSession(
            root: root,
            start: Date(),
            appName: "zoom")
        try managed.createFolder()
        try Data("Alpha line\nsecond line\n".utf8).write(to: managed.noteURL)
        let reads = ReadCounter()
        let index = TranscriptSearchIndex(loader: TranscriptTextLoader { url in
            reads.increment()
            return try String(contentsOf: url, encoding: .utf8)
        })

        let first = await index.search("alpha", root: root)
        let cached = await index.search("second", root: root)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(reads.value, 1)

        try Data("Beta replacement line\n".utf8).write(
            to: managed.noteURL,
            options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: managed.noteURL.path)
        let refreshed = await index.search("beta", root: root)

        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(reads.value, 2)

        try FileManager.default.removeItem(at: managed.noteURL)
        let deleted = await index.search("beta", root: root)
        XCTAssertTrue(deleted.isEmpty)
        await index.remove(root: root)
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meetscribe-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        return url
    }

    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }
    }
}
