import Foundation

enum AppPhase: Equatable {
    case idle
    case recording(start: Date)
    case transcribing
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var lastError: String?
    @Published var recentRecordings: [URL] = []
}
