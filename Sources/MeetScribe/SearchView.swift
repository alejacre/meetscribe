import SwiftUI

struct SearchHit: Identifiable {
    let id = UUID()
    let folder: URL
    let file: URL
    let line: String
}

/// Case-insensitive grep over MEETSCRIBE meeting notes in the output folder. Scans
/// `*.md` that own a `.assets/<basename>/` sidecar (so hand-curated vault notes are
/// skipped). No index: at the current scale a direct scan is instant.
enum TranscriptSearch {
    static func search(_ query: String, root: URL) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let fm = FileManager.default
        let notes = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .filter { fm.fileExists(atPath: RecordingSession(existingNote: $0).assetDir.path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var hits: [SearchHit] = []
        for md in notes {
            guard let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n")
            where line.localizedCaseInsensitiveContains(q) {
                hits.append(SearchHit(folder: md, file: md,
                                      line: line.trimmingCharacters(in: .whitespaces)))
                if hits.count >= 100 { return hits }
            }
        }
        return hits
    }
}

struct SearchView: View {
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searched = false

    init(
        query: String = "",
        hits: [SearchHit] = [],
        searched: Bool = false
    ) {
        _query = State(initialValue: query)
        _hits = State(initialValue: hits)
        _searched = State(initialValue: searched)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search transcripts…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .onSubmit {
                    hits = TranscriptSearch.search(query, root: Settings().outputFolder)
                    searched = true
                }
            Divider()
            if hits.isEmpty {
                Text(searched ? "No matches" : "Type a query and press Return")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(hits) { hit in
                    Button {
                        NSWorkspace.shared.open(hit.file)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.folder.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(hit.line)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 320)
    }
}
