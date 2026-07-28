import Foundation

enum ClaudeCleaner {
    static let prompt = """
    You are a transcript editor. Clean up the meeting transcript below: fix punctuation and casing, \
    remove filler words (um, eh, vale vale, you know) and false starts, and merge fragments into \
    coherent paragraphs. STRICT RULES: keep every [hh:mm:ss] timestamp and every **Me:**/**Them:** \
    label exactly as-is; keep each language (Spanish/English) as spoken  -  do not translate; do not \
    summarize, reorder, or omit content in the transcript body; keep the YAML frontmatter block \
    (between the opening and closing ---) exactly as-is; keep the trailing \
    <!-- meetscribe: ... --> comment exactly as-is.

    Additionally:
    1. The FIRST line of your output must be exactly: <!-- topic: <slug> --> where <slug> is 1-3 \
    lowercase words joined by hyphens describing what the meeting is about (e.g. q3-budget-review, \
    incident-triage, standup). Use the transcript's main language for the slug.
    2. Right after the frontmatter's closing --- line, insert a "## Summary" section: 2-4 sentences \
    describing what was discussed and any decisions or action items, in the transcript's main language.
    3. Then the "## Transcript" heading followed by the cleaned transcript body, and finally the \
    unchanged <!-- meetscribe: ... --> comment.

    Output ONLY the markdown, no commentary.
    """

    struct Result {
        let markdown: String
        let topicSlug: String?
    }

    enum CleanError: Error, LocalizedError {
        case notLoggedIn
        case invalidOutput
        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                "claude CLI is not logged in  -  run `claude /login`"
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
        guard let bin = binary ?? ToolFinder.findTool("claude") else { return nil }
        let raw = try Subprocess.run(
            bin,
            ["-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence", prompt],
            stdin: markdown,
            timeout: 300,
            environment: Subprocess.restrictedEnvironment)
        if isLoginFailure(raw) { throw CleanError.notLoggedIn }
        let (slug, body) = extractTopic(raw)
        guard structurallyValid(original: markdown, cleaned: body) else {
            throw CleanError.invalidOutput
        }
        return Result(markdown: body, topicSlug: slug)
    }

    /// Parses the leading `<!-- topic: slug -->` line; returns (slug, markdown without that line).
    static func extractTopic(_ text: String) -> (String?, String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("<!-- topic:"), first.hasSuffix("-->") else { return (nil, text) }
        let slug = RecordingSession.slug(
            first.dropFirst("<!-- topic:".count).dropLast("-->".count)
                .trimmingCharacters(in: .whitespaces))
        lines.removeFirst()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        return (slug.isEmpty ? nil : String(slug), body)
    }

    static func structurallyValid(original: String, cleaned: String) -> Bool {
        guard let summary = cleaned.range(of: "## Summary"),
              let transcript = cleaned.range(of: "## Transcript"),
              summary.lowerBound < transcript.lowerBound,
              frontmatter(in: original) == frontmatter(in: cleaned),
              metadataComment(in: original) == metadataComment(in: cleaned)
        else { return false }
        return turnMarkers(in: original) == turnMarkers(in: cleaned)
    }

    private static func frontmatter(in markdown: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---")
        else { return nil }
        return lines[...closing].joined(separator: "\n")
    }

    private static func metadataComment(in markdown: String) -> String? {
        markdown.split(separator: "\n").map(String.init)
            .first { $0.hasPrefix("<!-- meetscribe:") && $0.hasSuffix("-->") }
    }

    private static func turnMarkers(in markdown: String) -> [String] {
        let pattern = #"\[\d{2}:\d{2}:\d{2}\] \*\*(?:Me|Them):\*\*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.matches(in: markdown, range: range).compactMap {
            Range($0.range, in: markdown).map { String(markdown[$0]) }
        }
    }
}
