import SwiftUI

@main
struct MeetScribeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text(menuTitle)
            Divider()
            Button("Quit MeetScribe") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
        switch state.phase {
        case .idle: "waveform"
        case .recording: "record.circle.fill"
        case .transcribing: "hourglass"
        }
    }

    private var menuTitle: String {
        switch state.phase {
        case .idle: "MeetScribe  -  idle"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        }
    }
}
