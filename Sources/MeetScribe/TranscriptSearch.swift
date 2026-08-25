import Foundation

struct SearchHit: Identifiable, Sendable {
    let id: UUID
    let folder: URL
    let file: URL
    let line: String

    init(
        id: UUID = UUID(),
        folder: URL,
        file: URL,
        line: String
    ) {
        self.id = id
        self.folder = folder
        self.file = file
        self.line = line
    }
}

struct TranscriptTextLoader: Sendable {
    let load: @Sendable (URL) throws -> String

    static let live = TranscriptTextLoader {
        try String(contentsOf: $0, encoding: .utf8)
    }
}

actor TranscriptSearchIndex {
    private struct Signature: Equatable, Sendable {
        let modifiedAt: Date?
        let fileSize: Int?
    }

    private struct IndexedTranscript: Sendable {
        let signature: Signature
        let lines: [String]
    }

    static let shared = TranscriptSearchIndex()

    private let loader: TranscriptTextLoader
    private var entriesByRoot: [String: [String: IndexedTranscript]] = [:]

    init(loader: TranscriptTextLoader = .live) {
        self.loader = loader
    }

    func search(_ query: String, root: URL) -> [SearchHit] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, !Task.isCancelled else { return [] }

        let rootKey = root.standardizedFileURL.path
        let notes = TranscriptSearch.managedNotes(root: root)
        let activePaths = Set(notes.map { $0.standardizedFileURL.path })
        var entries = entriesByRoot[rootKey] ?? [:]
        entries = entries.filter { activePaths.contains($0.key) }
        defer { entriesByRoot[rootKey] = entries }

        var hits: [SearchHit] = []
        for markdown in notes {
            guard !Task.isCancelled else { return [] }
            let path = markdown.standardizedFileURL.path
            guard let signature = Self.signature(for: markdown) else { continue }

            let indexed: IndexedTranscript
            if let cached = entries[path], cached.signature == signature {
                indexed = cached
            } else {
                guard let text = try? loader.load(markdown) else { continue }
                indexed = IndexedTranscript(
                    signature: signature,
                    lines: text.split(separator: "\n").map(String.init))
                entries[path] = indexed
            }

            for line in indexed.lines {
                guard !Task.isCancelled else { return [] }
                guard line.localizedCaseInsensitiveContains(normalizedQuery) else {
                    continue
                }
                hits.append(SearchHit(
                    folder: markdown,
                    file: markdown,
                    line: line.trimmingCharacters(in: .whitespaces)))
                if hits.count >= 100 { return hits }
            }
        }
        return hits
    }

    func matchingRecordingIDs(_ query: String, root: URL) -> Set<String> {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, !Task.isCancelled else { return [] }

        let notes = TranscriptSearch.managedNotes(root: root)
        refreshEntries(for: notes, root: root)
        let rootKey = root.standardizedFileURL.path
        let entries = entriesByRoot[rootKey] ?? [:]
        var matches: Set<String> = []
        for markdown in notes {
            guard !Task.isCancelled else { return [] }
            let path = markdown.standardizedFileURL.path
            let filenameMatches = markdown.deletingPathExtension().lastPathComponent
                .localizedCaseInsensitiveContains(normalizedQuery)
            guard filenameMatches || entries[path]?.lines.contains(where: {
                $0.localizedCaseInsensitiveContains(normalizedQuery)
            }) == true
            else {
                continue
            }
            matches.insert(RecordingSession(existingNote: markdown).assetDir.standardizedFileURL.path)
        }
        return matches
    }

    func remove(root: URL) {
        entriesByRoot.removeValue(forKey: root.standardizedFileURL.path)
    }

    private static func signature(for url: URL) -> Signature? {
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey])
        else {
            return nil
        }
        return Signature(
            modifiedAt: values.contentModificationDate,
            fileSize: values.fileSize)
    }

    private func refreshEntries(for notes: [URL], root: URL) {
        let rootKey = root.standardizedFileURL.path
        let activePaths = Set(notes.map { $0.standardizedFileURL.path })
        var entries = entriesByRoot[rootKey] ?? [:]
        entries = entries.filter { activePaths.contains($0.key) }
        for markdown in notes {
            guard !Task.isCancelled else { return }
            let path = markdown.standardizedFileURL.path
            guard let signature = Self.signature(for: markdown) else { continue }
            if entries[path]?.signature == signature { continue }
            guard let text = try? loader.load(markdown) else { continue }
            entries[path] = IndexedTranscript(
                signature: signature,
                lines: text.split(separator: "\n").map(String.init))
        }
        entriesByRoot[rootKey] = entries
    }
}

enum TranscriptSearch {
    static func search(_ query: String, root: URL) async -> [SearchHit] {
        await TranscriptSearchIndex.shared.search(query, root: root)
    }

    static func matchingRecordingIDs(_ query: String, root: URL) async -> Set<String> {
        await TranscriptSearchIndex.shared.matchingRecordingIDs(query, root: root)
    }

    fileprivate static func managedNotes(root: URL) -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
            ])) ?? [])
            .filter { $0.pathExtension == "md" }
            .filter {
                fm.fileExists(
                    atPath: RecordingSession(existingNote: $0).assetDir.path)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
