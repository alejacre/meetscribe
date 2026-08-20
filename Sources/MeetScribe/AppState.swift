import Foundation

enum AppPhase: Equatable {
    case idle
    case starting
    case recording
    case stopping
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var elapsedSeconds: Int = 0
    @Published var transcribingCount: Int = 0
    @Published var publishingCount: Int = 0
    @Published var lastError: String?
    @Published var showPermissionHelp: Bool = false
    @Published var isQuitting: Bool = false
    @Published var recentRecordings: [RecordingRecord] = []
    @Published var recordingBrowserSelection: URL?
    @Published var recordingBrowserSearchRequested = false
}
