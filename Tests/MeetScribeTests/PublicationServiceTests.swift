import XCTest
@testable import MeetScribe

final class PublicationServiceTests: XCTestCase {
    func testFailedPublicationIsPersistedAndEligibleForResume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-publication-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = RecordingSession(root: root, start: Date(), appName: nil)
        try session.createFolder()
        try Data("# Transcript\n".utf8).write(to: session.noteURL)
        let configuration = DestinationConfiguration(
            git: GitDestinationConfiguration(
                enabled: true,
                repositoryPath: root.appendingPathComponent("missing-repository").path,
                relativePath: "meetings",
                includeAudio: false),
            sftp: SFTPDestinationConfiguration())

        let results = PublicationService.publish(
            session: session,
            configuration: configuration)

        let result = try XCTUnwrap(results.first)
        let manifest = try RecordingManifestStore.load(from: session.manifestURL)
        let publication = try XCTUnwrap(
            manifest.destinations.first { $0.destinationID == "git" })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(publication.phase, .failed)
        XCTAssertEqual(publication.attempts, 1)
        XCTAssertNotNil(publication.lastError)
        XCTAssertNotNil(manifest.publicationRequestedAt)
        XCTAssertTrue(PublicationService.needsResume(
            session: session,
            configuration: configuration))
    }

    func testSuccessfulPublicationIsPersistedAndNeedsNoResume() throws {
        let root = try temporaryDirectory("publication-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "--bare", remote.path])
        try runGit(["-C", repository.path, "init"])
        try runGit(["-C", repository.path, "config", "user.name", "MeetScribe Tests"])
        try runGit(["-C", repository.path, "config", "user.email", "tests@example.invalid"])
        try Data("initial\n".utf8).write(to: repository.appendingPathComponent("README.md"))
        try runGit(["-C", repository.path, "add", "README.md"])
        try runGit(["-C", repository.path, "commit", "-m", "Initial commit"])
        try runGit(["-C", repository.path, "remote", "add", "origin", remote.path])
        try runGit(["-C", repository.path, "push", "-u", "origin", "HEAD"])
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let session = RecordingSession(root: recordings, start: Date(), appName: "zoom")
        try session.createFolder()
        try Data("# Transcript\n".utf8).write(to: session.noteURL)
        try Data("{}".utf8).write(to: session.transcriptJSON)
        let configuration = DestinationConfiguration(
            git: GitDestinationConfiguration(
                enabled: true,
                repositoryPath: repository.path,
                relativePath: "meetings",
                includeAudio: false),
            sftp: SFTPDestinationConfiguration())

        let result = try XCTUnwrap(PublicationService.publish(
            session: session,
            configuration: configuration).first)

        let manifest = try RecordingManifestStore.load(from: session.manifestURL)
        let publication = try XCTUnwrap(
            manifest.destinations.first { $0.destinationID == "git" })
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(publication.phase, .succeeded)
        XCTAssertEqual(publication.attempts, 1)
        XCTAssertNotNil(publication.publishedAt)
        XCTAssertFalse(PublicationService.needsResume(
            session: session,
            configuration: configuration))
    }

    func testUnrequestedPublicationDoesNotResume() throws {
        let root = try temporaryDirectory("publication-unrequested")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(root: root, start: Date(), appName: nil)
        try session.createFolder()
        var configuration = DestinationConfiguration()
        configuration.git.enabled = true
        configuration.git.repositoryPath = root.path

        XCTAssertFalse(PublicationService.needsResume(
            session: session,
            configuration: configuration))
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        try Subprocess.run("/usr/bin/git", arguments, timeout: 30)
    }
}
