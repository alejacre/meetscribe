import XCTest
@testable import MeetScribe

final class RetentionServiceTests: XCTestCase {
    func testPostTranscriptionDeletesOnlySourceTracksWhenEnabled() throws {
        let root = try temporaryDirectory("retention-tracks")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try populatedSession(root: root, completedAt: Date())

        try RetentionService.applyPostTranscription(
            session: session,
            configuration: RetentionConfiguration(
                deleteSourceTracksAfterTranscription: true))

        XCTAssertFalse(FileManager.default.fileExists(atPath: session.micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.mixURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.noteURL.path))
    }

    func testAgePoliciesDeleteOnlyExpiredSelectedArtifacts() throws {
        let root = try temporaryDirectory("retention-age")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 2_000_000)
        let session = try populatedSession(
            root: root,
            completedAt: now.addingTimeInterval(-31 * 24 * 60 * 60))
        let recordings = try RecordingLibrary.recordings(root: root, limit: nil)

        try RetentionService.applyAgePolicies(
            recordings: recordings,
            configuration: RetentionConfiguration(
                audioRetentionDays: 30,
                rawTranscriptRetentionDays: 90),
            now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: session.mixURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.transcriptJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.noteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.manifestURL.path))
    }

    private func populatedSession(root: URL, completedAt: Date) throws -> RecordingSession {
        let session = RecordingSession(root: root, start: completedAt, appName: "test")
        try session.createFolder()
        try Data("# Transcript\n".utf8).write(to: session.noteURL)
        for url in [session.micURL, session.systemURL, session.mixURL, session.transcriptJSON] {
            try Data("private".utf8).write(to: url)
        }
        try RecordingManifestStore.update(at: session.manifestURL) { manifest in
            manifest.lifecycle = .ready
            manifest.transcript = TranscriptRunMetadata(
                completedAt: completedAt,
                model: "test",
                processorID: nil)
        }
        return session
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
