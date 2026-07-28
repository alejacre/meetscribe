import SwiftUI

@main
struct MeetScribeApp: App {
    @StateObject private var state: AppState
    @StateObject private var coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow
    private let firstRun = !Settings().setupCompleted

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
                Button("Start manual recording (all system audio)") {
                    Task { await coordinator.startRecording() }
                }
            case .starting:
                Button("Cancel recording startup") { Task { await coordinator.stopRecording() } }
            case .recording:
                Button("Stop recording (\(TranscriptFormatter.hms(Double(state.elapsedSeconds))))") {
                    Task { await coordinator.stopRecording() }
                }
            case .stopping:
                Text("Stopping recording…")
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
                    ForEach(state.recentRecordings) { record in
                        let session = RecordingSession(existingNote: record.noteURL)
                        Menu(record.basename) {
                            Button("Open transcript") { NSWorkspace.shared.open(record.noteURL) }
                                .disabled(!record.hasTranscript)
                            Button("Copy summary") { copySummary(session) }
                                .disabled(!record.hasTranscript)
                            if !record.hasTranscript {
                                Button("Retry transcription") {
                                    coordinator.retryTranscription(note: record.noteURL)
                                }
                            }
                            Button("Play audio") { NSWorkspace.shared.open(session.mixURL) }
                                .disabled(!FileManager.default.fileExists(atPath: session.mixURL.path))
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    record.hasTranscript ? record.noteURL : record.assetDir
                                ])
                            }
                            Divider()
                            Button("Move recording to Trash") { coordinator.moveToTrash(record) }
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
            Button("Setup assistant…") {
                openWindow(id: "setup")
                NSApp.activate(ignoringOtherApps: true)
            }
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
                .accessibilityLabel(menuBarAccessibilityLabel)
        }
        SwiftUI.Settings { SettingsView() }
        Window("Search transcripts", id: "search") { SearchView() }
            .windowResizability(.contentSize)
        Window("MeetScribe Setup", id: "setup") { SetupView() }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(firstRun ? .presented : .suppressed)
            .restorationBehavior(.disabled)
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
        case .starting, .stopping: return "hourglass"
        case .idle: return state.transcribingCount > 0 ? "hourglass" : "waveform"
        }
    }

    private var menuBarAccessibilityLabel: String {
        switch state.phase {
        case .idle: state.transcribingCount > 0 ? "MeetScribe transcribing" : "MeetScribe idle"
        case .starting: "MeetScribe starting recording"
        case .recording: "MeetScribe recording"
        case .stopping: "MeetScribe stopping recording"
        }
    }

}
