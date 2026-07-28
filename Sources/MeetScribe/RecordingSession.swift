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
        // note already owns the name). Probe for a free slot, checking BOTH the note and
        // its `.assets/<base>/` dir: a recording whose transcription failed leaves the
        // asset dir (audio) on disk but never writes the `.md`, so probing the note alone
        // would hand the same dir to the next recording and overwrite its audio.
        let fm = FileManager.default
        let assetsRoot = root.appendingPathComponent(".assets", isDirectory: true)
        func taken(_ name: String) -> Bool {
            fm.fileExists(atPath: root.appendingPathComponent(name + ".md").path)
                || fm.fileExists(atPath: assetsRoot.appendingPathComponent(name, isDirectory: true).path)
        }
        var name = base
        var n = 2
        while taken(name) {
            name = "\(base)-\(n)"
            n += 1
        }
        self.noteURL = root.appendingPathComponent(name + ".md")
    }

    init(existingNote: URL, start: Date? = nil) {
        self.noteURL = existingNote
        let datePart = String(existingNote.deletingPathExtension().lastPathComponent.prefix(10))
        self.start = start ?? Self.headerDateFormatter.date(from: datePart) ?? Date()
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
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: assetDir.path)
    }

    func secureFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path)
    }

    func removeAssetDirectoryIfEmpty() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: assetDir.path),
              contents.isEmpty else { return }
        try? fm.removeItem(at: assetDir)
    }
}
