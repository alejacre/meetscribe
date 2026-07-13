import SwiftUI

struct SearchHit: Identifiable {
    let id = UUID()
    let folder: URL
    let file: URL
    let line: String
}

/// Case-insensitive grep over */transcript.md in the output folder. No index:
/// at the current scale a direct scan is instant.
enum TranscriptSearch {
    static func search(_ query: String, root: URL) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var hits: [SearchHit] = []
        for dir in dirs {
            let md = dir.appendingPathComponent("transcript.md")
            guard let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n")
            where line.localizedCaseInsensitiveContains(q) {
                hits.append(SearchHit(folder: dir, file: md,
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
