import SwiftUI

@main
struct MeetScribeApp: App {
    @StateObject private var state: AppState
    @StateObject private var coordinator: RecordingCoordinator

    init() {
        let s = AppState()
        _state = StateObject(wrappedValue: s)
        _coordinator = StateObject(wrappedValue: RecordingCoordinator(state: s))
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
            }
            Divider()
            if !state.recentRecordings.isEmpty {
                Menu("Recent recordings") {
                    ForEach(state.recentRecordings, id: \.self) { url in
                        let rec = RecordingSession(existingFolder: url, start: Date())
                        Menu(url.lastPathComponent) {
                            Button("Open transcript") { NSWorkspace.shared.open(rec.transcriptMD) }
                                .disabled(!FileManager.default.fileExists(atPath: rec.transcriptMD.path))
                            Button("Play audio") { NSWorkspace.shared.open(rec.mixURL) }
                                .disabled(!FileManager.default.fileExists(atPath: rec.mixURL.path))
                            Button("Show in Finder") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
            Button("Open recordings folder") { NSWorkspace.shared.open(Settings().outputFolder) }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit MeetScribe") {
                // Don't lose an in-flight recording: stop and save before exiting.
                if case .recording = state.phase {
                    Task {
                        await coordinator.stopRecording()
                        NSApplication.shared.terminate(nil)
                    }
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }.keyboardShortcut("q")
        } label: {
            Image(systemName: iconName)
        }
        SwiftUI.Settings { SettingsView() }
    }

    private var iconName: String {
        switch state.phase {
        case .recording: return "record.circle.fill"
        case .idle: return state.transcribingCount > 0 ? "hourglass" : "waveform"
        }
    }

}
