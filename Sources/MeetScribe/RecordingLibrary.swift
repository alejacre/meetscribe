import Foundation

struct RecordingRecord: Identifiable, Equatable, Sendable {
    let noteURL: URL
    let assetDir: URL
    let modifiedAt: Date
    let manifest: RecordingManifest?

    var id: String { assetDir.standardizedFileURL.path }
    var basename: String { assetDir.lastPathComponent }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: noteURL.path) }
    var hasPublicationFailure: Bool {
        manifest?.destinations.contains { $0.phase == .failed } == true
    }
}

enum RecordingLibrary {
    static func recordings(root: URL, limit: Int? = 5) -> [RecordingRecord] {
        let fm = FileManager.default
        let assetsRoot = root.appendingPathComponent(".assets", isDirectory: true)
        let dirs = (try? fm.contentsOfDirectory(
            at: assetsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        return dirs.compactMap { dir in
            let values = try? dir.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let note = root.appendingPathComponent(dir.lastPathComponent + ".md")
            return RecordingRecord(
                noteURL: note,
                assetDir: dir,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                manifest: RecordingManifestStore.loadIfPresent(
                    from: dir.appendingPathComponent("manifest.json")))
        }
        .sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.basename > $1.basename
        }
        .withLimit(limit)
    }
}

enum RecordingFinalizer {
    static func move(_ session: RecordingSession, toTopicSlug slug: String) throws -> URL {
        let fm = FileManager.default
        let root = session.noteURL.deletingLastPathComponent()
        let assetsRoot = session.assetDir.deletingLastPathComponent()
        let base = "\(session.datePart)-\(RecordingSession.slug(slug))"

        var candidate = base
        var suffix = 2
        while candidate != session.basename,
              (fm.fileExists(atPath: root.appendingPathComponent(candidate + ".md").path)
               || fm.fileExists(atPath: assetsRoot.appendingPathComponent(candidate).path)) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }

        guard candidate != session.basename else { return session.noteURL }
        let noteDestination = root.appendingPathComponent(candidate + ".md")
        let assetDestination = assetsRoot.appendingPathComponent(candidate, isDirectory: true)

        try fm.moveItem(at: session.assetDir, to: assetDestination)
        do {
            try fm.moveItem(at: session.noteURL, to: noteDestination)
        } catch {
            try? fm.moveItem(at: assetDestination, to: session.assetDir)
            throw error
        }
        return noteDestination
    }
}

private extension Array {
    func withLimit(_ limit: Int?) -> [Element] {
        guard let limit else { return self }
        return Array(prefix(limit))
    }
}
