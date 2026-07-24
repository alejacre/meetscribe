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
        var errorDescription: String? {
            "claude CLI is not logged in  -  run `claude /login`"
        }
    }

    /// `claude -p` reports an expired/missing login as a normal-looking reply
    /// ("Not logged in · Please run /login") rather than a distinct exit code.
    static func isLoginFailure(_ text: String) -> Bool {
        text.contains("Not logged in") || text.contains("Please run /login")
    }

    /// Resolved once per app run  -  the binary's location can't change mid-session and
    /// the login-shell fallback is expensive (sources the full zsh profile).
    static let resolvedBinary: String? = ToolFinder.findTool("claude")

    /// Returns cleaned markdown + topic slug, or nil if claude is unavailable/fails
    /// (caller falls back to the raw transcript). Throws `CleanError.notLoggedIn` so
    /// the caller can tell the user to re-auth instead of silently keeping the raw note.
    static func clean(_ markdown: String) throws -> Result? {
        guard let bin = resolvedBinary else { return nil }
        let raw = try? Subprocess.run(bin, ["-p", prompt], stdin: markdown, timeout: 300)
        if let raw, isLoginFailure(raw) { throw CleanError.notLoggedIn }
        // Sanity gate: a valid result must still carry the frontmatter and the transcript
        // body; otherwise fall back to the raw whisper note.
        guard let raw, raw.contains("date:"), raw.contains("## Transcript") else { return nil }
        let (slug, body) = extractTopic(raw)
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
}
