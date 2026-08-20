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

    func testSuccessfulTranscriptionDoesNotClearAnotherRecordingFailure() {
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            enableSystemIntegrations: false)

        coordinator.recordTranscriptionFailure("temporary failure", for: "recording-a")
        coordinator.clearTranscriptionFailure(for: "recording-b")

        XCTAssertEqual(state.lastError, "Transcription failed: temporary failure")
    }

    func testSuccessfulRetryClearsMatchingTranscriptionFailure() {
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            enableSystemIntegrations: false)

        coordinator.recordTranscriptionFailure("temporary failure", for: "recording-a")
        coordinator.clearTranscriptionFailure(for: "recording-a")

        XCTAssertNil(state.lastError)
    }

    func testSuccessfulRetryPreservesNewerUnrelatedWarning() {
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            enableSystemIntegrations: false)

        coordinator.recordTranscriptionFailure("temporary failure", for: "recording-a")
        state.lastError = "Publishing failed: repository unavailable"
        coordinator.clearTranscriptionFailure(for: "recording-a")

        XCTAssertEqual(state.lastError, "Publishing failed: repository unavailable")
    }

    func testPromptRecordingTargetsSelectedMeetingApplication() async {
        let recorder = CapturingFailingRecorder()
        let coordinator = RecordingCoordinator(
            state: AppState(),
            recorderFactory: { recorder },
            enableSystemIntegrations: false)
        let meeting = DetectedMeeting(
            bundleID: "com.microsoft.teams2",
            appName: "teams")

        await coordinator.startRecording(trigger: .meetingPrompt, meeting: meeting)

        XCTAssertEqual(recorder.targetBundleID, meeting.bundleID)
    }

    func testManualRecordingDoesNotInheritMeetingTarget() async {
        let recorder = CapturingFailingRecorder()
        let coordinator = RecordingCoordinator(
            state: AppState(),
            recorderFactory: { recorder },
            enableSystemIntegrations: false)

        await coordinator.startRecording()

        XCTAssertNil(recorder.targetBundleID)
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

    private final class CapturingFailingRecorder: AudioRecording, @unchecked Sendable {
        var sourceWarning: String?
        var onStreamDied: ((Error) -> Void)?
        private(set) var targetBundleID: String?

        func start(session: RecordingSession, targetBundleID: String?) async throws {
            self.targetBundleID = targetBundleID
            throw TestError.expected
        }

        func stop() async throws {}
    }
}
