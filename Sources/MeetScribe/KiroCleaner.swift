import Foundation

enum KiroCleaner {
    static let prompt = TranscriptProcessorSupport.defaultPrompt
    static let agentName = "meetscribe-transcript"

    struct Result {
        let markdown: String
        let topicSlug: String
    }

    enum CleanError: Error, LocalizedError {
        case unavailable
        case missingTopic
        case invalidOutput
        case sessionCleanupFailed

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Kiro CLI is configured, but the `kiro-cli` executable is unavailable"
            case .missingTopic:
                "Kiro returned a transcript without the required topic name"
            case .invalidOutput:
                "Kiro returned an incomplete or structurally unsafe transcript"
            case .sessionCleanupFailed:
                "Kiro processed the transcript, but its temporary local session could not be deleted"
            }
        }
    }

    static func clean(_ markdown: String, binary: String? = nil) throws -> Result? {
        guard let bin = binary ?? ToolFinder.findTool("kiro-cli"),
              FileManager.default.isExecutableFile(atPath: bin)
        else {
            throw CleanError.unavailable
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meetscribe-kiro-\(UUID().uuidString.lowercased())",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try createAgent(in: workspace)

        var environment = Subprocess.restrictedEnvironment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        let request = prompt + "\n\nTranscript follows:\n\n" + markdown
        let raw: String
        do {
            raw = try Subprocess.run(
                bin,
                [
                    "chat",
                    "--agent", agentName,
                    "--no-interactive",
                    "--wrap", "never",
                ],
                stdin: request,
                timeout: TranscriptProcessorSupport.timeout(for: markdown),
                environment: environment,
                currentDirectory: workspace)
        } catch {
            _ = try? deleteSessions(
                binary: bin,
                workspace: workspace,
                environment: environment)
            throw error
        }

        do {
            try deleteSessions(
                binary: bin,
                workspace: workspace,
                environment: environment)
        } catch {
            throw CleanError.sessionCleanupFailed
        }

        let output = extractMarkdown(from: raw)
        let (slug, body) = TranscriptProcessorSupport.extractTopic(output)
        guard let slug else { throw CleanError.missingTopic }
        guard TranscriptProcessorSupport.structurallyValid(
            original: markdown,
            processed: body)
        else {
            throw CleanError.invalidOutput
        }
        return Result(markdown: body, topicSlug: slug)
    }

    static func extractMarkdown(from output: String) -> String {
        var plain = output.replacingOccurrences(
            of: #"\u001B\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression)
        // Kiro's non-interactive terminal renderer consumes Markdown syntax:
        // horizontal rules become box-drawing lines and bold speaker labels lose
        // their asterisks. Restore the constrained syntax required by the shared
        // structural validator before accepting any output.
        plain = plain.replacingOccurrences(
            of: #"(?m)^[━─]{3,}\s*$"#,
            with: "---",
            options: .regularExpression)
        plain = plain.replacingOccurrences(
            of: #"(?m)^(\[\d{2}:\d{2}:\d{2}\])\s+(Me|Them):"#,
            with: "$1 **$2:**",
            options: .regularExpression)
        guard let start = plain.range(of: "<!-- topic:") else { return plain }
        var markdown = String(plain[start.lowerBound...])
        if let credits = markdown.range(
            of: #"\n\s*▸ Credits:"#,
            options: .regularExpression)
        {
            markdown = String(markdown[..<credits.lowerBound])
        }
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func createAgent(in workspace: URL) throws {
        let agents = workspace
            .appendingPathComponent(".kiro", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: agents,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let config = """
            {
              "name": "\(agentName)",
              "description": "Processes a MeetScribe transcript without tools or MCP servers.",
              "model": "auto",
              "includeMcpJson": false,
              "prompt": "Follow the user request exactly. Do not use tools.",
              "tools": [],
              "allowedTools": [],
              "mcpServers": {}
            }
            """
        let url = agents.appendingPathComponent("\(agentName).json")
        try Data(config.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path)
    }

    private struct SessionEnvelope: Decodable {
        let sessions: [Session]
    }

    private struct Session: Decodable {
        let sessionId: String
    }

    private static func deleteSessions(
        binary: String,
        workspace: URL,
        environment: [String: String]
    ) throws {
        let listing = try Subprocess.run(
            binary,
            ["chat", "--list-sessions", "--format", "json"],
            timeout: 30,
            environment: environment,
            currentDirectory: workspace)
        let envelopes = try JSONDecoder().decode(
            [SessionEnvelope].self,
            from: Data(listing.utf8))
        for session in envelopes.flatMap(\.sessions) {
            _ = try Subprocess.run(
                binary,
                ["chat", "--delete-session", session.sessionId],
                timeout: 30,
                environment: environment,
                currentDirectory: workspace)
        }
    }
}
