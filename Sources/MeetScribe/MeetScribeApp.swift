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
                        Button(url.lastPathComponent) { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Button("Open recordings folder") { NSWorkspace.shared.open(Settings().outputFolder) }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit MeetScribe") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
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
