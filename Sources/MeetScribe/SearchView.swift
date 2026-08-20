import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searched = false
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

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
                    startSearch()
                }
            Divider()
            if searching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hits.isEmpty {
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
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func startSearch() {
        searchTask?.cancel()
        let submittedQuery = query
        let root = Settings().outputFolder
        searched = false
        searching = true
        searchTask = Task { @MainActor in
            let result = await TranscriptSearch.search(
                submittedQuery,
                root: root)
            guard !Task.isCancelled else { return }
            guard query == submittedQuery else {
                searching = false
                return
            }
            hits = result
            searched = true
            searching = false
        }
    }
}
