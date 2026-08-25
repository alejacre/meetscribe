import AppKit
import SwiftUI

@MainActor
final class RecordingsViewModel: ObservableObject {
    private(set) var root: URL
    @Published var recordings: [RecordingRecord] = []
    @Published var documents: [String: TranscriptDocument] = [:]
    @Published var selectedID: String?
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published var isLoading = false
    @Published private(set) var isSearching = false
    @Published var error: String?

    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var matchingRecordingIDs: Set<String>?

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    var visibleRecordings: [RecordingRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return recordings }
        guard let matchingRecordingIDs else { return [] }
        return recordings.filter { matchingRecordingIDs.contains($0.id) }
    }

    var selectedRecording: RecordingRecord? {
        recordings.first { $0.id == selectedID }
    }

    func reload(root newRoot: URL? = nil, selecting noteURL: URL? = nil) {
        loadTask?.cancel()
        searchTask?.cancel()
        if let newRoot {
            root = newRoot.standardizedFileURL
        }
        isLoading = true
        isSearching = false
        matchingRecordingIDs = nil
        error = nil
        let root = root
        let previousSelection = selectedID
        loadTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<([RecordingRecord], [String: TranscriptDocument]), Error> in
                do {
                    let recordings = try RecordingLibrary.recordings(root: root, limit: nil)
                    let documents: [String: TranscriptDocument] = Dictionary(
                        uniqueKeysWithValues: recordings.compactMap { recording in
                            guard recording.hasTranscript,
                                  let document = try? TranscriptDocument.load(from: recording.noteURL)
                            else {
                                return nil
                            }
                            return (recording.id, document)
                        })
                    return .success((recordings, documents))
                } catch {
                    return .failure(error)
                }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let loaded):
                recordings = loaded.0
                documents = loaded.1
                let requestedID = noteURL.flatMap { requested in
                    loaded.0.first { $0.noteURL.standardizedFileURL == requested.standardizedFileURL }?.id
                }
                if let requestedID {
                    selectedID = requestedID
                } else if let previousSelection,
                          loaded.0.contains(where: { $0.id == previousSelection })
                {
                    selectedID = previousSelection
                } else {
                    selectedID = loaded.0.first?.id
                }
                scheduleSearch()
            case .failure(let loadError):
                recordings = []
                documents = [:]
                selectedID = nil
                error = loadError.localizedDescription
            }
            isLoading = false
        }
    }

    func select(noteURL: URL?) {
        guard let noteURL else { return }
        if let match = recordings.first(where: {
            $0.noteURL.standardizedFileURL == noteURL.standardizedFileURL
        }) {
            selectedID = match.id
        } else {
            reload(selecting: noteURL)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            matchingRecordingIDs = nil
            isSearching = false
            return
        }

        matchingRecordingIDs = nil
        isSearching = true
        let root = root
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            let matches = await TranscriptSearch.matchingRecordingIDs(
                normalized,
                root: root)
            guard !Task.isCancelled,
                  query.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
            else {
                return
            }
            matchingRecordingIDs = matches
            isSearching = false
        }
    }
}

struct RecordingsView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: RecordingsViewModel
    @FocusState private var searchFocused: Bool
    private let rootOverride: URL?
    private let onRetryTranscription: (URL) -> Void
    private let onRetryPublication: (URL) -> Void

    init(
        state: AppState,
        root: URL? = nil,
        onRetryTranscription: @escaping (URL) -> Void = { _ in },
        onRetryPublication: @escaping (URL) -> Void = { _ in }
    ) {
        _state = ObservedObject(wrappedValue: state)
        rootOverride = root
        self.onRetryTranscription = onRetryTranscription
        self.onRetryPublication = onRetryPublication
        _model = StateObject(wrappedValue: RecordingsViewModel(
            root: root ?? Settings().outputFolder))
    }

    var body: some View {
        NavigationSplitView {
            recordingList
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            detail
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search transcripts")
        .searchFocused($searchFocused)
        .frame(minWidth: 900, minHeight: 600)
        .task {
            reload(selecting: state.recordingBrowserSelection)
            focusSearchIfRequested()
        }
        .onChange(of: state.recordingBrowserSelection) { _, selection in
            model.select(noteURL: selection)
        }
        .onChange(of: state.recordingBrowserSearchRequested) { _, requested in
            if requested {
                focusSearchIfRequested()
            }
        }
        .onChange(of: state.recentRecordings) { _, _ in
            reload(selecting: state.recordingBrowserSelection)
        }
        .onReceive(NotificationCenter.default.publisher(for: Settings.outputFolderChanged)) { _ in
            guard rootOverride == nil else { return }
            reload(selecting: state.recordingBrowserSelection)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    reload(selecting: model.selectedRecording?.noteURL)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh recordings")

                Button {
                    guard let record = model.selectedRecording else { return }
                    NSWorkspace.shared.open(record.noteURL)
                } label: {
                    Label("Open Markdown", systemImage: "arrow.up.forward.app")
                }
                .disabled(model.selectedRecording?.hasTranscript != true)
                .help("Open transcript in the default Markdown app")

                Button {
                    guard let record = model.selectedRecording else { return }
                    NSWorkspace.shared.open(
                        RecordingSession(existingNote: record.noteURL).mixURL)
                } label: {
                    Label("Play Audio", systemImage: "play.circle")
                }
                .disabled(!selectedAudioExists)
                .help("Play recording audio")

                Button {
                    guard let record = model.selectedRecording else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([
                        record.hasTranscript ? record.noteURL : record.assetDir
                    ])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .disabled(model.selectedRecording == nil)
                .help("Show recording in Finder")
            }
        }
    }

    private var recordingList: some View {
        List(selection: $model.selectedID) {
            if model.isLoading, model.recordings.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if let error = model.error {
                ContentUnavailableView(
                    "Could not load recordings",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if model.recordings.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform",
                    description: Text("Completed recordings will appear here."))
            } else if model.isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if model.visibleRecordings.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                ForEach(groupedRecordings, id: \.month) { group in
                    Section(group.month) {
                        ForEach(group.recordings) { record in
                            RecordingRow(
                                record: record,
                                document: model.documents[record.id])
                                .tag(record.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Recordings")
    }

    @ViewBuilder
    private var detail: some View {
        if let record = model.selectedRecording {
            if let document = model.documents[record.id] {
                TranscriptDetailView(
                    record: record,
                    document: document,
                    onRetryPublication: {
                        onRetryPublication(record.noteURL)
                    })
            } else {
                ContentUnavailableView {
                    Label("Transcript unavailable", systemImage: "waveform.badge.exclamationmark")
                } description: {
                    Text("The audio is retained locally. Retry transcription from the menu bar.")
                } actions: {
                    Button("Retry transcription") {
                        onRetryTranscription(record.noteURL)
                    }
                    Button("Show recording in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([record.assetDir])
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a recording",
                systemImage: "text.document",
                description: Text("Choose a transcript from the sidebar."))
        }
    }

    private var groupedRecordings: [(month: String, recordings: [RecordingRecord])] {
        let grouped = Dictionary(grouping: model.visibleRecordings) { record in
            Self.monthFormatter.string(from: recordDate(record))
        }
        return grouped
            .map { (month: $0.key, recordings: $0.value) }
            .sorted {
                let left = $0.recordings.first.map(recordDate) ?? .distantPast
                let right = $1.recordings.first.map(recordDate) ?? .distantPast
                return left > right
            }
    }

    private var selectedAudioExists: Bool {
        guard let record = model.selectedRecording else { return false }
        return FileManager.default.fileExists(
            atPath: RecordingSession(existingNote: record.noteURL).mixURL.path)
    }

    private func focusSearchIfRequested() {
        guard state.recordingBrowserSearchRequested else { return }
        searchFocused = true
        state.recordingBrowserSearchRequested = false
    }

    private func reload(selecting noteURL: URL?) {
        model.reload(
            root: rootOverride ?? Settings().outputFolder,
            selecting: noteURL)
    }

    private func recordDate(_ record: RecordingRecord) -> Date {
        record.manifest?.startedAt
            ?? RecordingSession.headerDateFormatter.date(
                from: String(record.basename.prefix(10)))
            ?? record.modifiedAt
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
}

struct RecordingRow: View {
    let record: RecordingRecord
    let document: TranscriptDocument?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.hasTranscript ? "text.document.fill" : "waveform.badge.exclamationmark")
                .foregroundStyle(record.hasTranscript ? Color.accentColor : Color.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(document?.title ?? TranscriptDocument.title(from: record.basename))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(dateText)
                    if let app = record.manifest?.source.appName ?? document?.sourceApp {
                        Text("·")
                        Text(app.capitalized)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if record.manifestError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Recovery metadata could not be read")
            }
        }
        .padding(.vertical, 3)
    }

    private var dateText: String {
        if let date = document?.date,
           let parsed = RecordingSession.headerDateFormatter.date(from: date)
        {
            return parsed.formatted(date: .abbreviated, time: .omitted)
        }
        return String(record.basename.prefix(10))
    }
}

struct TranscriptDetailView: View {
    let record: RecordingRecord
    let document: TranscriptDocument
    var onRetryPublication: () -> Void = {}

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                if let manifestError = record.manifestError {
                    Label(
                        "Recovery metadata could not be read: \(manifestError)",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if record.hasPublicationFailure {
                    Label(
                        "One or more exports failed.",
                        systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Button("Retry failed exports", action: onRetryPublication)
                }
                Divider()
                if let summary = document.summary {
                    transcriptSection("Summary") {
                        Text(summary)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                    }
                }
                if !document.decisions.isEmpty {
                    transcriptSection("Decisions") {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(Array(document.decisions.enumerated()), id: \.offset) { _, decision in
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text(decision)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                transcriptSection("Transcript") {
                    if let unstructured = document.unstructuredTranscript {
                        Text(unstructured)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                    }
                    if document.turns.isEmpty,
                       document.unstructuredTranscript == nil
                    {
                        Text("No timestamped turns were found in this transcript.")
                            .foregroundStyle(.secondary)
                    } else if !document.turns.isEmpty {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(document.turns.enumerated()), id: \.offset) { index, turn in
                                TranscriptTurnRow(turn: turn)
                                if index < document.turns.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 42)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle(document.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(document.title)
                .font(.system(size: 32, weight: .bold))
                .textSelection(.enabled)
            HStack(spacing: 14) {
                if let date = displayDate {
                    Label(date, systemImage: "calendar")
                }
                if let app = record.manifest?.source.appName ?? document.sourceApp {
                    Label(app.capitalized, systemImage: "video")
                }
                if let duration = document.duration {
                    Label(duration, systemImage: "clock")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if !document.tags.isEmpty {
                Text(document.tags.map { "#\($0)" }.joined(separator: "   "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var displayDate: String? {
        guard let date = document.date else { return nil }
        guard let parsed = RecordingSession.headerDateFormatter.date(from: date) else {
            return date
        }
        return parsed.formatted(date: .long, time: .omitted)
    }

    private func transcriptSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            content()
        }
    }
}

struct TranscriptTurnRow: View {
    let turn: TranscriptTurn

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16) {
            GridRow {
                Text(turn.timestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 64, alignment: .leading)
                Text(turn.speaker)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(speakerColor)
                    .frame(width: 58, alignment: .leading)
                Text(turn.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 12)
    }

    private var speakerColor: Color {
        turn.speaker.localizedCaseInsensitiveCompare("Me") == .orderedSame
            ? .accentColor
            : .secondary
    }
}
