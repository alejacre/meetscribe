import Foundation

struct RecordingSession: Sendable {
    let folder: URL
    let start: Date

    init(root: URL, start: Date, appName: String?) {
        self.start = start
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let app = (appName ?? "manual")
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        self.folder = root.appendingPathComponent("\(fmt.string(from: start))_\(app)")
    }

    init(existingFolder: URL, start: Date) {
        self.folder = existingFolder
        self.start = start
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
