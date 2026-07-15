import Foundation

/// A recording maps to a flat Obsidian-style note `<root>/<date>-<slug>.md` plus a
/// hidden asset directory `<root>/.assets/<date>-<slug>/` holding the audio + raw JSON.
/// This matches the vault's meeting-note convention (Obsidian ignores dot-folders, so
/// the media never clutters the vault or the graph).
struct RecordingSession: Sendable {
    let noteURL: URL
    let start: Date
    let appName: String?

    static let stampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// `date:` value written into the note's YAML frontmatter.
    static let headerDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// Lowercased, hyphen-separated, filesystem-safe slug shared by note naming
    /// and Claude topic slugs.
    static func slug(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    init(root: URL, start: Date, appName: String?) {
        self.start = start
        self.appName = appName
        let stamp = Self.stampFormatter.string(from: start)
        let base = "\(stamp)-\(Self.slug(appName ?? "manual"))"
        // Date-only names collide when two meetings happen the same day (or a curated
        // note already owns the name). Probe for a free `<base>-n.md`.
        var candidate = root.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        self.noteURL = candidate
    }

    init(existingNote: URL, start: Date = Date()) {
        self.noteURL = existingNote
        self.start = start
        self.appName = nil
    }

    /// `2026-07-14-q2-fba-qbr` (note filename without the `.md` extension).
    var basename: String { noteURL.deletingPathExtension().lastPathComponent }

    /// The `yyyy-MM-dd` prefix, used to rebuild the name once Claude supplies a topic slug.
    var datePart: String { String(basename.prefix(10)) }

    var assetDir: URL {
        noteURL.deletingLastPathComponent()
            .appendingPathComponent(".assets", isDirectory: true)
            .appendingPathComponent(basename, isDirectory: true)
    }

    var micURL: URL { assetDir.appendingPathComponent("mic.m4a") }
    var systemURL: URL { assetDir.appendingPathComponent("system.m4a") }
    var mixURL: URL { assetDir.appendingPathComponent("audio.m4a") }
    var transcriptMD: URL { noteURL }
    var transcriptJSON: URL { assetDir.appendingPathComponent("transcript.json") }

    func createFolder() throws {
        try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
    }
}
