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
            case .recording(let start):
                Button("Stop recording (\(elapsed(since: start)))") { Task { await coordinator.stopRecording() } }
            case .transcribing:
                Text("Transcribing…")
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
        case .idle: "waveform"
        case .recording: "record.circle.fill"
        case .transcribing: "hourglass"
        }
    }

    private func elapsed(since start: Date) -> String {
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
