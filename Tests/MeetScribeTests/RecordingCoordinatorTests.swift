import XCTest
@testable import MeetScribe

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func testStopRequestedDuringStartupStopsAfterCaptureStarts() async {
        let recorder = SuspendedRecorder()
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            recorderFactory: { recorder },
            mixer: { _ in throw TestError.expected },
            enableSystemIntegrations: false)

        let startTask = Task { await coordinator.startRecording() }
        while !recorder.startEntered { await Task.yield() }
        XCTAssertEqual(state.phase, .starting)

        await coordinator.stopRecording()
        recorder.finishStarting()
        await startTask.value

        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(state.phase, .idle)
    }

    private enum TestError: Error { case expected }

    private final class SuspendedRecorder: AudioRecording, @unchecked Sendable {
        var sourceWarning: String?
        var onStreamDied: ((Error) -> Void)?
        private(set) var startEntered = false
        private(set) var stopCount = 0
        private var continuation: CheckedContinuation<Void, Never>?

        func start(session: RecordingSession, targetBundleID: String?) async throws {
            startEntered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func finishStarting() {
            continuation?.resume()
            continuation = nil
        }

        func stop() async throws { stopCount += 1 }
    }
}
