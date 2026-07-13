import Foundation

struct RecordingSession: Sendable {
    let folder: URL
    let start: Date
    let appName: String?

    static let stampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    static let headerDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// Lowercased, hyphen-separated, filesystem-safe slug shared by folder naming
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
        let base = "\(stamp)_\(Self.slug(appName ?? "manual"))"
        // Timestamps have minute granularity: a stop+start within the same minute
        // would silently reuse the live folder. Probe for a free name instead.
        var candidate = root.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        self.folder = candidate
    }

    init(existingFolder: URL, start: Date) {
        self.folder = existingFolder
        self.start = start
        self.appName = nil
    }

    var micURL: URL { folder.appendingPathComponent("mic.m4a") }
    var systemURL: URL { folder.appendingPathComponent("system.m4a") }
    var mixURL: URL { folder.appendingPathComponent("audio.m4a") }
    var transcriptMD: URL { folder.appendingPathComponent("transcript.md") }
    var transcriptJSON: URL { folder.appendingPathComponent("transcript.json") }

    func createFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
