import CryptoKit
import Foundation

struct DestinationCommandRunner: Sendable {
    let run: @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ stdin: String?,
        _ timeout: TimeInterval,
        _ environment: [String: String]?
    ) throws -> String

    static let live = DestinationCommandRunner { executable, arguments, stdin, timeout, environment in
        try Subprocess.run(
            executable,
            arguments,
            stdin: stdin,
            timeout: timeout,
            environment: environment)
    }
}

struct RecordingExportFile: Equatable, Sendable {
    let sourceURL: URL
    let relativePath: String
}

struct RecordingExportPackage: Sendable {
    let recordingID: UUID
    let basename: String
    let files: [RecordingExportFile]

    init(session: RecordingSession, includeAudio: Bool) throws {
        guard FileManager.default.fileExists(atPath: session.noteURL.path) else {
            throw DestinationError.missingTranscript
        }

        recordingID = session.id
        basename = session.basename
        var files = [
            RecordingExportFile(
                sourceURL: session.noteURL,
                relativePath: session.noteURL.lastPathComponent)
        ]
        let assetPrefix = ".assets/\(session.basename)"
        for url in [session.manifestURL, session.transcriptJSON]
        where FileManager.default.fileExists(atPath: url.path) {
            files.append(RecordingExportFile(
                sourceURL: url,
                relativePath: "\(assetPrefix)/\(url.lastPathComponent)"))
        }
        if includeAudio {
            for url in [session.mixURL, session.micURL, session.systemURL]
            where FileManager.default.fileExists(atPath: url.path) {
                files.append(RecordingExportFile(
                    sourceURL: url,
                    relativePath: "\(assetPrefix)/\(url.lastPathComponent)"))
            }
        }
        self.files = files
    }

    func materialize(at root: URL) throws {
        for file in files {
            let destination = root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try AtomicFileCopy.copy(file.sourceURL, to: destination)
        }
    }
}

protocol RecordingDestination: Sendable {
    var id: String { get }
    var displayName: String { get }
    var configurationFingerprint: String { get }
    var includeAudio: Bool { get }

    func validateConnection() throws
    func publish(_ package: RecordingExportPackage) throws
}

enum DestinationError: Error, LocalizedError {
    case missingTranscript
    case invalidRepository
    case repositoryPathMustBeRoot
    case repositoryHasUnmanagedChanges(String)
    case missingGitUpstream
    case invalidRelativePath
    case invalidSFTPHost
    case invalidRemotePath

    var errorDescription: String? {
        switch self {
        case .missingTranscript:
            "The recording does not have a transcript to publish."
        case .invalidRepository:
            "Choose an existing Git repository."
        case .repositoryPathMustBeRoot:
            "Choose the root folder of the Git repository."
        case .repositoryHasUnmanagedChanges(let path):
            "The Git repository has unrelated changes at \(path). Commit or discard them before publishing."
        case .missingGitUpstream:
            "The current Git branch has no upstream remote."
        case .invalidRelativePath:
            "The Git destination path must be relative and cannot contain '..'."
        case .invalidSFTPHost:
            "Enter an SSH host or alias that does not start with '-'."
        case .invalidRemotePath:
            "Enter an SFTP destination path without control characters."
        }
    }
}

struct GitRepositoryDestination: RecordingDestination {
    let id = "git"
    let displayName = "Git repository"
    let configuration: GitDestinationConfiguration
    let runner: DestinationCommandRunner

    init(
        configuration: GitDestinationConfiguration,
        runner: DestinationCommandRunner = .live
    ) {
        self.configuration = configuration
        self.runner = runner
    }

    var includeAudio: Bool { configuration.includeAudio }
    var configurationFingerprint: String { fingerprint(configuration) }

    func validateConnection() throws {
        let root = repositoryRoot
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw DestinationError.invalidRepository
        }
        let reported = try git(["-C", root.path, "rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: reported).standardizedFileURL == root.standardizedFileURL else {
            throw DestinationError.repositoryPathMustBeRoot
        }
        try requireUpstream()
    }

    func publish(_ package: RecordingExportPackage) throws {
        try validateConnection()
        let managedRoot = try Self.validatedRelativePath(configuration.relativePath)
        let root = repositoryRoot
        let targetRoot = managedRoot.isEmpty ? root : root.appendingPathComponent(managedRoot)
        let targetPaths = package.files.map {
            managedRoot.isEmpty ? $0.relativePath : "\(managedRoot)/\($0.relativePath)"
        }
        try ensureExistingChangesAreLimited(to: Set(targetPaths))
        try package.materialize(at: targetRoot)

        _ = try git(["-C", root.path, "add", "--"] + targetPaths)
        let staged = try git(["-C", root.path, "diff", "--cached", "--name-only", "--"] + targetPaths)
        if !staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try git([
                "-C", root.path,
                "commit", "-m", "Add meeting \(package.basename)",
                "--",
            ] + targetPaths)
        }

        _ = try git(["-C", root.path, "push"])
    }

    static func validatedRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "" }
        let components = trimmed.split(
            separator: "/",
            omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              !components.contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              })
        else {
            throw DestinationError.invalidRelativePath
        }
        return trimmed
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: (configuration.repositoryPath as NSString).expandingTildeInPath)
    }

    private func ensureExistingChangesAreLimited(to allowedPaths: Set<String>) throws {
        let output = try git([
            "-C", repositoryRoot.path,
            "status", "--porcelain=v1", "--untracked-files=all",
        ])
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.count >= 4 else { continue }
            var path = String(line.dropFirst(3))
            if let rename = path.range(of: " -> ") {
                path = String(path[rename.upperBound...])
            }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard allowedPaths.contains(path) else {
                throw DestinationError.repositoryHasUnmanagedChanges(path)
            }
        }
    }

    private func git(_ arguments: [String]) throws -> String {
        let executable = ToolFinder.findTool("git") ?? "/usr/bin/git"
        return try runner.run(executable, arguments, nil, 180, nil)
    }

    private func requireUpstream() throws {
        do {
            _ = try git([
                "-C", repositoryRoot.path,
                "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
            ])
        } catch {
            throw DestinationError.missingGitUpstream
        }
    }
}

struct SFTPDestination: RecordingDestination {
    let id = "sftp"
    let displayName = "SFTP over SSH"
    let configuration: SFTPDestinationConfiguration
    let runner: DestinationCommandRunner

    init(
        configuration: SFTPDestinationConfiguration,
        runner: DestinationCommandRunner = .live
    ) {
        self.configuration = configuration
        self.runner = runner
    }

    var includeAudio: Bool { configuration.includeAudio }
    var configurationFingerprint: String { fingerprint(configuration) }

    func validateConnection() throws {
        try Self.validateHost(configuration.host)
        let remoteRoot = try Self.validatedRemotePath(configuration.remotePath)
        _ = try runner.run(
            "/usr/bin/sftp",
            Self.arguments(host: configuration.host),
            try SFTPBatch.validationCommands(remoteRoot: remoteRoot),
            30,
            ProcessInfo.processInfo.environment)
    }

    func publish(_ package: RecordingExportPackage) throws {
        try Self.validateHost(configuration.host)
        let remoteRoot = try Self.validatedRemotePath(configuration.remotePath)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-sftp-\(UUID().uuidString)", isDirectory: true)
        let localPackage = tempRoot.appendingPathComponent(package.basename, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: localPackage, withIntermediateDirectories: true)
        try package.materialize(at: localPackage)

        let batch = try SFTPBatch.commands(
            localDirectory: localPackage,
            remoteRoot: remoteRoot,
            finalDirectory: package.basename,
            uploadID: "\(package.recordingID.uuidString.lowercased())-\(UUID().uuidString.lowercased())")
        _ = try runner.run(
            "/usr/bin/sftp",
            Self.arguments(host: configuration.host),
            batch,
            600,
            ProcessInfo.processInfo.environment)
    }

    static func validateHost(_ host: String) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw DestinationError.invalidSFTPHost
        }
    }

    static func validatedRemotePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
              !trimmed.split(separator: "/").contains("..")
        else {
            throw DestinationError.invalidRemotePath
        }
        return path.hasPrefix("/") ? "/\(trimmed)" : trimmed
    }

    private static func arguments(host: String) -> [String] {
        [
            "-b", "-",
            "-oBatchMode=yes",
            "-oStrictHostKeyChecking=yes",
            host,
        ]
    }
}

enum SFTPBatch {
    static func validationCommands(remoteRoot: String) throws -> String {
        """
        cd \(try quote(remoteRoot))
        pwd
        """
    }

    static func commands(
        localDirectory: URL,
        remoteRoot: String,
        finalDirectory: String,
        uploadID: String
    ) throws -> String {
        let incomingRoot = "\(remoteRoot)/.meetscribe-incoming"
        let remoteTemporary = "\(incomingRoot)/\(uploadID)"
        let remoteFinal = "\(remoteRoot)/\(finalDirectory)"
        return """
            -mkdir \(try quote(incomingRoot))
            put -R \(try quote(localDirectory.path)) \(try quote(remoteTemporary))
            rename \(try quote(remoteTemporary)) \(try quote(remoteFinal))
            """
    }

    private static func quote(_ value: String) throws -> String {
        guard !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
            throw DestinationError.invalidRemotePath
        }
        return "\""
            + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}

private enum AtomicFileCopy {
    static func copy(_ source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: source, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

private func fingerprint<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
