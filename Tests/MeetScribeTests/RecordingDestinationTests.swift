import XCTest
@testable import MeetScribe

final class RecordingDestinationTests: XCTestCase {
    func testExportPackageExcludesAudioByDefault() throws {
        let root = try temporaryDirectory("export")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try populatedSession(root: root)

        let package = try RecordingExportPackage(session: session, includeAudio: false)
        let paths = Set(package.files.map(\.relativePath))

        XCTAssertTrue(paths.contains(session.noteURL.lastPathComponent))
        XCTAssertTrue(paths.contains(".assets/\(session.basename)/manifest.json"))
        XCTAssertTrue(paths.contains(".assets/\(session.basename)/transcript.json"))
        XCTAssertFalse(paths.contains(".assets/\(session.basename)/audio.m4a"))
    }

    func testSFTPBatchUsesTemporaryDirectoryAndAtomicRename() throws {
        let batch = try SFTPBatch.commands(
            localDirectory: URL(fileURLWithPath: "/tmp/meeting \"one\""),
            remoteRoot: "/srv/recordings",
            finalDirectory: "2026-08-20-planning",
            uploadID: "upload-1")

        XCTAssertTrue(batch.contains("-mkdir \"/srv/recordings/.meetscribe-incoming\""))
        XCTAssertTrue(batch.contains(
            "put -R \"/tmp/meeting \\\"one\\\"\" \"/srv/recordings/.meetscribe-incoming/upload-1\""))
        XCTAssertTrue(batch.contains(
            "rename \"/srv/recordings/.meetscribe-incoming/upload-1\" \"/srv/recordings/2026-08-20-planning\""))
    }

    func testSFTPValidationChecksQuotedRemoteFolder() throws {
        XCTAssertEqual(
            try SFTPBatch.validationCommands(remoteRoot: "/srv/meeting notes"),
            """
            cd "/srv/meeting notes"
            pwd
            """)
    }

    func testSFTPRejectsOptionInjectionAndUnsafeRemotePath() {
        XCTAssertThrowsError(try SFTPDestination.validateHost("-oProxyCommand=bad"))
        XCTAssertThrowsError(try SFTPDestination.validateHost("archive\rhost"))
        XCTAssertThrowsError(try SFTPDestination.validatedRemotePath("/srv/\nrecordings"))
        XCTAssertThrowsError(try SFTPDestination.validatedRemotePath("/srv/\trecordings"))
        XCTAssertThrowsError(try SFTPDestination.validatedRemotePath("/srv/../recordings"))
    }

    func testGitRelativePathValidation() throws {
        XCTAssertEqual(
            try GitRepositoryDestination.validatedRelativePath("meetings/team/"),
            "meetings/team")
        XCTAssertEqual(try GitRepositoryDestination.validatedRelativePath(""), "")
        XCTAssertThrowsError(
            try GitRepositoryDestination.validatedRelativePath("../meetings"))
        XCTAssertThrowsError(
            try GitRepositoryDestination.validatedRelativePath("/absolute"))
    }

    func testGitValidationRequiresUpstream() throws {
        let root = try temporaryDirectory("git-no-upstream")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["-C", repository.path, "init"])
        let destination = GitRepositoryDestination(configuration: GitDestinationConfiguration(
            enabled: true,
            repositoryPath: repository.path,
            relativePath: "meetings",
            includeAudio: false))

        XCTAssertThrowsError(try destination.validateConnection()) { error in
            guard case DestinationError.missingGitUpstream = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testGitDestinationCommitsAndPushesToConfiguredUpstream() throws {
        let root = try temporaryDirectory("git")
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, remote) = try initializedRepository(in: root)
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let session = try populatedSession(root: recordings)
        let destination = GitRepositoryDestination(configuration: GitDestinationConfiguration(
            enabled: true,
            repositoryPath: repository.path,
            relativePath: "meetings",
            includeAudio: false))

        try destination.publish(RecordingExportPackage(session: session, includeAudio: false))

        let note = repository.appendingPathComponent("meetings/\(session.noteURL.lastPathComponent)")
        let manifest = repository.appendingPathComponent(
            "meetings/.assets/\(session.basename)/manifest.json")
        let audio = repository.appendingPathComponent(
            "meetings/.assets/\(session.basename)/audio.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(
            try runGit(["-C", repository.path, "status", "--porcelain"])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "")
        XCTAssertTrue(
            try runGit(["--git-dir", remote.path, "log", "-1", "--pretty=%s"])
                .contains("Add meeting \(session.basename)"))
    }

    func testGitDestinationRejectsUnrelatedWorkingTreeChanges() throws {
        let root = try temporaryDirectory("git-dirty")
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, _) = try initializedRepository(in: root)
        try Data("unrelated".utf8).write(
            to: repository.appendingPathComponent("unrelated.txt"))
        let session = try populatedSession(
            root: root.appendingPathComponent("recordings", isDirectory: true))
        let destination = GitRepositoryDestination(configuration: GitDestinationConfiguration(
            enabled: true,
            repositoryPath: repository.path,
            relativePath: "meetings",
            includeAudio: false))

        XCTAssertThrowsError(
            try destination.publish(RecordingExportPackage(session: session, includeAudio: false))
        ) { error in
            guard case DestinationError.repositoryHasUnmanagedChanges("unrelated.txt") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func populatedSession(root: URL) throws -> RecordingSession {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = RecordingSession(
            root: root,
            start: Date(timeIntervalSince1970: 1_776_969_600),
            appName: "zoom",
            bundleID: "us.zoom.xos",
            trigger: .meetingPrompt)
        try session.createFolder()
        try Data("# Meeting\n".utf8).write(to: session.noteURL)
        try Data("{}".utf8).write(to: session.transcriptJSON)
        try Data("audio".utf8).write(to: session.mixURL)
        return session
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func initializedRepository(in root: URL) throws -> (repository: URL, remote: URL) {
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "--bare", remote.path])
        try runGit(["-C", repository.path, "init"])
        try runGit(["-C", repository.path, "config", "user.name", "MeetScribe Tests"])
        try runGit(["-C", repository.path, "config", "user.email", "tests@example.invalid"])
        try Data("test repository\n".utf8).write(
            to: repository.appendingPathComponent("README.md"))
        try runGit(["-C", repository.path, "add", "README.md"])
        try runGit(["-C", repository.path, "commit", "-m", "Initial commit"])
        try runGit(["-C", repository.path, "remote", "add", "origin", remote.path])
        try runGit(["-C", repository.path, "push", "-u", "origin", "HEAD"])
        return (repository, remote)
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        try Subprocess.run("/usr/bin/git", arguments, timeout: 30)
    }
}
