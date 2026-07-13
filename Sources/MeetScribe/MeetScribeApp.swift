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
                Button("Stop recording (\(elapsed(state.elapsedSeconds)))") {
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
                        Menu(url.lastPathComponent) {
                            Button("Open transcript") {
                                NSWorkspace.shared.open(url.appendingPathComponent("transcript.md"))
                            }
                            .disabled(!FileManager.default.fileExists(
                                atPath: url.appendingPathComponent("transcript.md").path))
                            Button("Play audio") {
                                NSWorkspace.shared.open(url.appendingPathComponent("audio.m4a"))
                            }
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

    private func elapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
