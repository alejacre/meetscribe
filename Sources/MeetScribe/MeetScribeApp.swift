import SwiftUI

@main
struct MeetScribeApp: App {
    @StateObject private var state: AppState
    @StateObject private var coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    init() {
        let s = AppState()
        _state = StateObject(wrappedValue: s)
        _coordinator = StateObject(wrappedValue: RecordingCoordinator(state: s))
        // LSUIElement apps can fall back to the generic icon in windows and
        // dialogs; pin the bundled icon explicitly.
        if let icns = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: icns) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        MenuBarExtra {
            switch state.phase {
            case .idle:
                Button("Start recording") { Task { await coordinator.startRecording() } }
            case .recording:
                Button("Stop recording (\(TranscriptFormatter.hms(Double(state.elapsedSeconds))))") {
                    Task { await coordinator.stopRecording() }
                }
            }
            if state.transcribingCount > 0 {
                Text(state.transcribingCount == 1 ? "Transcribing 1 recording…"
                                                  : "Transcribing \(state.transcribingCount) recordings…")
            }
            if let err = state.lastError {
                Divider()
                Text("Warning: \(err)").font(.caption)
                Button("Clear warning") { coordinator.clearError() }
                if state.showPermissionHelp {
                    Button("Open Screen Recording settings") {
                        openPrivacyPane("Privacy_ScreenCapture")
                    }
                    Button("Open Microphone settings") {
                        openPrivacyPane("Privacy_Microphone")
                    }
                }
            }
            Divider()
            if !state.recentRecordings.isEmpty {
                Menu("Recent recordings") {
                    ForEach(state.recentRecordings, id: \.self) { url in
                        let rec = RecordingSession(existingFolder: url, start: Date())
                        let hasTranscript = FileManager.default.fileExists(atPath: rec.transcriptMD.path)
                        Menu(url.lastPathComponent) {
                            Button("Open transcript") { NSWorkspace.shared.open(rec.transcriptMD) }
                                .disabled(!hasTranscript)
                            Button("Copy summary") { copySummary(rec) }
                                .disabled(!hasTranscript)
                            if !hasTranscript {
                                Button("Retry transcription") { coordinator.retryTranscription(folder: url) }
                            }
                            Button("Play audio") { NSWorkspace.shared.open(rec.mixURL) }
                                .disabled(!FileManager.default.fileExists(atPath: rec.mixURL.path))
                            Button("Show in Finder") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
            Button("Search transcripts…") {
                openWindow(id: "search")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Open recordings folder") { NSWorkspace.shared.open(Settings().outputFolder) }
            Divider()
            SettingsLink { Text("Settings…") }
            if state.isQuitting {
                Text("Quitting  -  waiting for transcription…")
            } else {
                Button(quitLabel) {
                    // Don't lose an in-flight recording or transcription: stop,
                    // wait for pending work (bounded), then exit.
                    state.isQuitting = true
                    Task { await coordinator.quitAfterPendingWork() }
                }.keyboardShortcut("q")
            }
        } label: {
            Image(systemName: iconName)
        }
        SwiftUI.Settings { SettingsView() }
        Window("Search transcripts", id: "search") { SearchView() }
            .windowResizability(.contentSize)
    }

    private var quitLabel: String {
        state.transcribingCount > 0 ? "Quit (will wait for transcription)" : "Quit MeetScribe"
    }

    private func copySummary(_ rec: RecordingSession) {
        guard let md = try? String(contentsOf: rec.transcriptMD, encoding: .utf8),
              let summary = TranscriptFormatter.extractSummary(md) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private var iconName: String {
        switch state.phase {
        case .recording: return "record.circle.fill"
        case .idle: return state.transcribingCount > 0 ? "hourglass" : "waveform"
        }
    }

}
