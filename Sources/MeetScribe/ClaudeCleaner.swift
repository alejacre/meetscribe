import Foundation

enum ClaudeCleaner {
    static let prompt = """
    You are a transcript editor. Clean up the meeting transcript below: fix punctuation and casing, \
    remove filler words (um, eh, vale vale, you know) and false starts, and merge fragments into \
    coherent paragraphs. STRICT RULES: keep every [hh:mm:ss] timestamp and every **Me:**/**Them:** \
    label exactly as-is; keep each language (Spanish/English) as spoken  -  do not translate; do not \
    summarize, reorder, or omit content; keep the markdown header untouched. Output ONLY the cleaned \
    markdown, no commentary.
    """

    /// Locates the claude CLI: fixed candidates first, then the user's login shell PATH
    /// (covers version-managed installs like mise/nvm whose paths change across upgrades).
    static func findBinary() -> String? {
        let candidates = [NSHomeDirectory() + "/.local/bin/claude", "/usr/local/bin/claude",
                          "/opt/homebrew/bin/claude"]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        guard let path = try? Subprocess.run("/bin/zsh", ["-lc", "which claude"])
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty, FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }

    /// Returns cleaned markdown, or nil if claude is unavailable/fails (caller falls back to raw).
    static func clean(_ markdown: String) -> String? {
        guard let bin = findBinary() else { return nil }
        let result = try? Subprocess.run(bin, ["-p", prompt], stdin: markdown)
        guard let result, result.contains("# Meeting transcript") else { return nil }
        return result
    }
}
