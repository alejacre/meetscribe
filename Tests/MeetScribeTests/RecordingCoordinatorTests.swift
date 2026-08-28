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

    func testRecordingForwardsExplicitAudioMode() async {
        let recorder = CapturingFailingRecorder()
        let coordinator = RecordingCoordinator(
            state: AppState(),
            recorderFactory: { recorder },
            enableSystemIntegrations: false)

        await coordinator.startRecording(audioMode: .systemOnly)

        XCTAssertEqual(recorder.audioMode, .systemOnly)
    }

    func testRecordingUsesConfiguredDefaultAudioMode() async throws {
        let root = try temporaryDirectory("coordinator-audio-mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let (baseSettings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        var settings = baseSettings
        settings.recordingAudioMode = .systemOnly
        let recorder = CapturingFailingRecorder()
        let coordinator = RecordingCoordinator(
            state: AppState(),
            settings: settings,
            recorderFactory: { recorder },
            enableSystemIntegrations: false)

        await coordinator.startRecording(trigger: .meetingAutomatic)

        XCTAssertEqual(recorder.audioMode, .systemOnly)
    }

    func testMeetingNotificationForwardsSelectedAudioMode() async throws {
        let root = try temporaryDirectory("coordinator-notification-audio-mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let meeting = DetectedMeeting(
            bundleID: "com.microsoft.teams2",
            appName: "teams")
        let detector = MeetingDetector(appDefinitions: {
            [meeting.bundleID: meeting.appName]
        })
        let notifier = Notifier()
        let recorder = CapturingFailingRecorder()
        let coordinator = RecordingCoordinator(
            state: AppState(),
            settings: settings,
            notifier: notifier,
            detector: detector,
            recorderFactory: { recorder },
            enableSystemIntegrations: false)

        detector.onMeetingStart?(meeting)
        try await waitUntil {
            coordinator.state.pendingMeetingPrompts == [meeting]
        }
        notifier.onRecordAction?(meeting.bundleID, .systemOnly)
        try await waitUntil { recorder.audioMode != nil }

        XCTAssertEqual(recorder.targetBundleID, meeting.bundleID)
        XCTAssertEqual(recorder.audioMode, .systemOnly)
    }

    func testManualRecordingTargetsOneDetectedMeeting() async throws {
        let root = try temporaryDirectory("coordinator-manual-meeting")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let meeting = DetectedMeeting(
            bundleID: "com.microsoft.teams2",
            appName: "teams")
        let detector = MeetingDetector(appDefinitions: {
            [meeting.bundleID: meeting.appName]
        })
        let recorder = FolderCreatingRecorder()
        let coordinator = RecordingCoordinator(
            state: AppState(),
            settings: settings,
            detector: detector,
            recorderFactory: { recorder },
            mixer: { _ in throw TestError.expected },
            enableSystemIntegrations: false)

        detector.onMeetingStart?(meeting)
        try await waitUntil {
            coordinator.state.pendingMeetingPrompts == [meeting]
        }
        await coordinator.startRecording()

        XCTAssertEqual(recorder.targetBundleID, meeting.bundleID)
        XCTAssertEqual(recorder.session?.sourceBundleID, meeting.bundleID)
        XCTAssertEqual(recorder.session?.trigger, .manual)
        await coordinator.stopRecording()
    }

    func testManualRecordingDoesNotAssociateWhenMultipleMeetingsAreDetected() async throws {
        let root = try temporaryDirectory("coordinator-multiple-meetings")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let teams = DetectedMeeting(
            bundleID: "com.microsoft.teams2",
            appName: "teams")
        let slack = DetectedMeeting(
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "slack")
        let detector = MeetingDetector(appDefinitions: { [
            teams.bundleID: teams.appName,
            slack.bundleID: slack.appName,
        ] })
        let recorder = FolderCreatingRecorder()
        let coordinator = RecordingCoordinator(
            state: AppState(),
            settings: settings,
            detector: detector,
            recorderFactory: { recorder },
            mixer: { _ in throw TestError.expected },
            enableSystemIntegrations: false)

        detector.onMeetingStart?(teams)
        detector.onMeetingStart?(slack)
        try await waitUntil {
            coordinator.state.pendingMeetingPrompts.count == 2
        }
        await coordinator.startRecording()

        XCTAssertNil(recorder.targetBundleID)
        XCTAssertNil(recorder.session?.sourceBundleID)
        XCTAssertEqual(recorder.session?.trigger, .manual)
        await coordinator.stopRecording()
    }

    func testManualRecordingDoesNotAssociateIgnoredMeeting() async throws {
        let root = try temporaryDirectory("coordinator-ignored-meeting")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let meeting = DetectedMeeting(
            bundleID: "com.microsoft.teams2",
            appName: "teams")
        var ignoredSettings = settings
        ignoredSettings.meetingRules = ignoredSettings.meetingRules.map { rule in
            var updated = rule
            if updated.bundleID == meeting.bundleID {
                updated.policy = .ignore
            }
            return updated
        }
        let detector = MeetingDetector(appDefinitions: {
            [meeting.bundleID: meeting.appName]
        })
        let recorder = FolderCreatingRecorder()
        let coordinator = RecordingCoordinator(
            state: AppState(),
            settings: ignoredSettings,
            detector: detector,
            recorderFactory: { recorder },
            mixer: { _ in throw TestError.expected },
            enableSystemIntegrations: false)

        detector.onMeetingStart?(meeting)
        try await Task.sleep(for: .milliseconds(10))
        await coordinator.startRecording()

        XCTAssertNil(recorder.targetBundleID)
        XCTAssertNil(recorder.session?.sourceBundleID)
        await coordinator.stopRecording()
    }

    func testHotKeyRecordingTargetsOneDetectedMeeting() async throws {
        let root = try temporaryDirectory("coordinator-hotkey-meeting")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let meeting = DetectedMeeting(
            bundleID: "com.microsoft.teams2",
            appName: "teams")
        let detector = MeetingDetector(appDefinitions: {
            [meeting.bundleID: meeting.appName]
        })
        let recorder = FolderCreatingRecorder()
        let coordinator = RecordingCoordinator(
            state: AppState(),
            settings: settings,
            detector: detector,
            recorderFactory: { recorder },
            mixer: { _ in throw TestError.expected },
            enableSystemIntegrations: false)

        detector.onMeetingStart?(meeting)
        try await waitUntil {
            coordinator.state.pendingMeetingPrompts == [meeting]
        }
        await coordinator.startRecording(trigger: .hotKey)

        XCTAssertEqual(recorder.targetBundleID, meeting.bundleID)
        XCTAssertEqual(recorder.session?.trigger, .hotKey)
        await coordinator.stopRecording()
    }

    func testMeetingRecordingStopsAfterSilenceTimeout() async throws {
        let root = try temporaryDirectory("coordinator-silence-stop")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let meeting = DetectedMeeting(
            bundleID: "com.microsoft.teams2",
            appName: "teams")
        let recorder = FolderCreatingRecorder()
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            settings: settings,
            recorderFactory: { recorder },
            mixer: { _ in throw TestError.expected },
            silenceAutoStopInterval: 300,
            enableSystemIntegrations: false)

        await coordinator.startRecording(
            trigger: .meetingPrompt,
            meeting: meeting)
        let activity = Date()
        recorder.lastMeetingAudioActivityAt = activity
        await coordinator.handleRecordingTimerTick(
            at: activity.addingTimeInterval(300))

        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(state.phase, .idle)
    }

    func testRecentActivityKeepsMeetingRecordingRunning() async throws {
        let root = try temporaryDirectory("coordinator-recent-activity")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let meeting = DetectedMeeting(
            bundleID: "com.microsoft.teams2",
            appName: "teams")
        let recorder = FolderCreatingRecorder()
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            settings: settings,
            recorderFactory: { recorder },
            mixer: { _ in throw TestError.expected },
            silenceAutoStopInterval: 300,
            enableSystemIntegrations: false)

        await coordinator.startRecording(
            trigger: .meetingPrompt,
            meeting: meeting)
        let activity = Date()
        recorder.lastMeetingAudioActivityAt = activity
        await coordinator.handleRecordingTimerTick(
            at: activity.addingTimeInterval(299))

        XCTAssertEqual(recorder.stopCount, 0)
        XCTAssertEqual(state.phase, .recording)
        await coordinator.stopRecording()
    }

    func testUnassociatedManualRecordingIgnoresSilenceTimeout() async throws {
        let root = try temporaryDirectory("coordinator-manual-silence")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let recorder = FolderCreatingRecorder()
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            settings: settings,
            recorderFactory: { recorder },
            mixer: { _ in throw TestError.expected },
            silenceAutoStopInterval: 1,
            enableSystemIntegrations: false)

        await coordinator.startRecording()
        let activity = Date()
        recorder.lastMeetingAudioActivityAt = activity
        await coordinator.handleRecordingTimerTick(
            at: activity.addingTimeInterval(10))

        XCTAssertEqual(recorder.stopCount, 0)
        XCTAssertEqual(state.phase, .recording)
        await coordinator.stopRecording()
    }

    func testAskPolicyKeepsActionablePromptUntilMeetingEnds() async throws {
        let root = try temporaryDirectory("coordinator-meeting-prompt")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let meeting = DetectedMeeting(
            bundleID: "com.microsoft.teams2",
            appName: "teams")
        let detector = MeetingDetector(appDefinitions: {
            [meeting.bundleID: meeting.appName]
        })
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            settings: settings,
            detector: detector,
            enableSystemIntegrations: false)

        detector.onMeetingStart?(meeting)
        try await waitUntil { state.pendingMeetingPrompts == [meeting] }

        detector.onMeetingEnd?(meeting)
        try await waitUntil { state.pendingMeetingPrompts.isEmpty }
        withExtendedLifetime(coordinator) {}
    }

    func testSuccessfulStopPersistsRecordedStateAndStartsBackgroundWork() async throws {
        let root = try temporaryDirectory("coordinator-stop")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let recorder = FolderCreatingRecorder()
        let state = AppState()
        let transcriptionCalls = LockedCounter()
        let coordinator = RecordingCoordinator(
            state: state,
            settings: settings,
            recorderFactory: { recorder },
            mixer: { _ in },
            transcriptionRunner: .init { session, _ in
                transcriptionCalls.increment()
                return RecordingTranscriptionResult(
                    finalSession: session,
                    processingWarning: nil,
                    processorID: nil)
            },
            enableSystemIntegrations: false)

        await coordinator.startRecording()
        XCTAssertEqual(state.phase, .recording)
        await coordinator.stopRecording()
        try await waitUntil {
            state.phase == .idle
                && state.transcribingCount == 0
                && transcriptionCalls.value == 1
        }

        let session = try XCTUnwrap(recorder.session)
        let manifest = try RecordingManifestStore.load(from: session.manifestURL)
        XCTAssertEqual(manifest.lifecycle, .recorded)
        XCTAssertNotNil(manifest.endedAt)
        XCTAssertEqual(recorder.stopCount, 1)
    }

    func testStopSurfacesManifestPersistenceFailure() async throws {
        let root = try temporaryDirectory("coordinator-manifest-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let recorder = FolderCreatingRecorder()
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            settings: settings,
            recorderFactory: { recorder },
            mixer: { _ in },
            enableSystemIntegrations: false)

        await coordinator.startRecording()
        let session = try XCTUnwrap(recorder.session)
        try Data("not json".utf8).write(
            to: session.manifestURL,
            options: .atomic)
        await coordinator.stopRecording()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(
            state.lastError?.contains(
                "Recovery state could not be saved") == true)
        XCTAssertEqual(state.transcribingCount, 0)
    }

    func testMoveToTrashIsBlockedWhileRecordingWorkIsActive() async throws {
        let root = try temporaryDirectory("coordinator-trash")
        defer { try? FileManager.default.removeItem(at: root) }
        let (settings, suite) = try makeSettings(root: root)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let session = RecordingSession(
            root: root,
            start: Date(),
            appName: "zoom")
        try session.createFolder()
        try Data("# Transcript\n".utf8).write(to: session.noteURL)
        let blocker = BlockingRunner(session: session)
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            settings: settings,
            transcriptionRunner: blocker.runner,
            enableSystemIntegrations: false)
        let record = RecordingRecord(
            noteURL: session.noteURL,
            assetDir: session.assetDir,
            modifiedAt: Date(),
            manifest: try RecordingManifestStore.load(from: session.manifestURL))

        coordinator.transcribeInBackground(session: session)
        try await waitUntil { blocker.callCount == 1 }
        coordinator.moveToTrash(record)

        XCTAssertTrue(
            state.lastError?.contains(
                "Wait for transcription or publishing") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.noteURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.assetDir.path))
        blocker.release()
        try await waitUntil { state.transcribingCount == 0 }
    }

    private enum TestError: Error { case expected }

    private final class SuspendedRecorder: AudioRecording, @unchecked Sendable {
        var sourceWarning: String?
        var onStreamDied: ((Error) -> Void)?
        private(set) var startEntered = false
        private(set) var stopCount = 0
        private var continuation: CheckedContinuation<Void, Never>?

        func start(
            session: RecordingSession,
            targetBundleID: String?,
            audioMode: RecordingAudioMode
        ) async throws {
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
        private(set) var audioMode: RecordingAudioMode?

        func start(
            session: RecordingSession,
            targetBundleID: String?,
            audioMode: RecordingAudioMode
        ) async throws {
            self.targetBundleID = targetBundleID
            self.audioMode = audioMode
            throw TestError.expected
        }

        func stop() async throws {}
    }

    private final class FolderCreatingRecorder: AudioRecording, @unchecked Sendable {
        var sourceWarning: String?
        var lastMeetingAudioActivityAt: Date?
        var onStreamDied: ((Error) -> Void)?
        private(set) var session: RecordingSession?
        private(set) var stopCount = 0
        private(set) var targetBundleID: String?
        private(set) var audioMode: RecordingAudioMode?

        func start(
            session: RecordingSession,
            targetBundleID: String?,
            audioMode: RecordingAudioMode
        ) async throws {
            self.session = session
            self.targetBundleID = targetBundleID
            self.audioMode = audioMode
            try session.createFolder()
        }

        func stop() async throws {
            stopCount += 1
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }

    private final class BlockingRunner: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private let session: RecordingSession
        private var calls = 0

        init(session: RecordingSession) {
            self.session = session
        }

        var runner: RecordingTranscriptionRunner {
            RecordingTranscriptionRunner { [self] _, _ in
                lock.withLock { calls += 1 }
                semaphore.wait()
                return RecordingTranscriptionResult(
                    finalSession: session,
                    processingWarning: nil,
                    processorID: nil)
            }
        }

        var callCount: Int {
            lock.withLock { calls }
        }

        func release() {
            semaphore.signal()
        }
    }

    private func makeSettings(root: URL) throws -> (Settings, String) {
        let suite = "test.meetscribe.coordinator.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        var settings = Settings(defaults: defaults)
        settings.outputFolder = root
        return (settings, suite)
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meetscribe-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition was not met before timeout")
    }
}
