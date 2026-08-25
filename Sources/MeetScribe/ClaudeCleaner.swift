import Foundation

enum ClaudeCleaner {
    static let prompt = TranscriptProcessorSupport.defaultPrompt
    static let model = "haiku"

    struct Result {
        let markdown: String
        let topicSlug: String
    }

    enum CleanError: Error, LocalizedError {
        case unavailable
        case notLoggedIn
        case missingTopic
        case invalidOutput
        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Claude Code is configured, but the `claude` executable is unavailable"
            case .notLoggedIn:
                "claude CLI is not logged in  -  run `claude /login`"
            case .missingTopic:
                "Claude returned a transcript without the required topic name"
            case .invalidOutput:
                "Claude returned an incomplete or structurally unsafe transcript"
            }
        }
    }

    /// `claude -p` reports an expired/missing login as a normal-looking reply
    /// ("Not logged in · Please run /login") rather than a distinct exit code.
    static func isLoginFailure(_ text: String) -> Bool {
        text.contains("Not logged in") || text.contains("Please run /login")
    }

    /// Returns cleaned markdown + topic slug, or nil if claude is unavailable.
    static func clean(_ markdown: String, binary: String? = nil) throws -> Result? {
        guard let bin = binary ?? ToolFinder.findTool("claude"),
              FileManager.default.isExecutableFile(atPath: bin)
        else {
            throw CleanError.unavailable
        }
        let raw = try Subprocess.run(
            bin,
            [
                "-p",
                "--model", model,
                "--tools", "",
                "--strict-mcp-config",
                "--no-session-persistence",
                prompt,
            ],
            stdin: markdown,
            timeout: TranscriptProcessorSupport.timeout(for: markdown),
            environment: Subprocess.restrictedEnvironment)
        if isLoginFailure(raw) { throw CleanError.notLoggedIn }
        let (slug, body) = extractTopic(raw)
        guard let slug else {
            throw CleanError.missingTopic
        }
        guard structurallyValid(original: markdown, cleaned: body) else {
            throw CleanError.invalidOutput
        }
        return Result(markdown: body, topicSlug: slug)
    }

    /// Parses the leading `<!-- topic: slug -->` line; returns (slug, markdown without that line).
    static func extractTopic(_ text: String) -> (String?, String) {
        TranscriptProcessorSupport.extractTopic(text)
    }

    static func structurallyValid(original: String, cleaned: String) -> Bool {
        TranscriptProcessorSupport.structurallyValid(original: original, processed: cleaned)
    }
}
