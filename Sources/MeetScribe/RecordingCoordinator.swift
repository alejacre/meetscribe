import Foundation
import AppKit

@MainActor
final class RecordingCoordinator: ObservableObject {
    static let meetingSilenceAutoStopMinutes = 5
    static let meetingSilenceAutoStopInterval =
        TimeInterval(meetingSilenceAutoStopMinutes * 60)

    let state: AppState
    let notifier: Notifier
    let detector: MeetingDetector
    private var recorder: (any AudioRecording)?
    private var session: RecordingSession?
    private var detectedMeetings: [String: DetectedMeeting] = [:]
    private var settings: Settings
    private var elapsedTimer: Timer?
    private var sleepActivity: NSObjectProtocol?
    private var hotKey: HotKey?
    private var stopRequestedDuringStart = false
    private let recorderFactory: () -> any AudioRecording
    private let mixer: (RecordingSession) async throws -> Void
    private let backgroundWork: RecordingBackgroundWorkController
    private let silenceAutoStopInterval: TimeInterval

    static let hotKeySettingChanged = Notification.Name("meetscribe.hotKeySettingChanged")

    init(
        state: AppState,
        settings: Settings = Settings(),
        notifier: Notifier = Notifier(),
        detector: MeetingDetector? = nil,
        recorderFactory: @escaping () -> any AudioRecording = { AudioRecorder() },
        mixer: @escaping (RecordingSession) async throws -> Void = { try await AudioRecorder.mix(session: $0) },
        transcriptionRunner: RecordingTranscriptionRunner = .live,
        publicationRunner: RecordingPublicationRunner = .live,
        silenceAutoStopInterval: TimeInterval = RecordingCoordinator.meetingSilenceAutoStopInterval,
        enableSystemIntegrations: Bool = true
    ) {
        self.state = state
        self.settings = settings
        self.notifier = notifier
        self.recorderFactory = recorderFactory
        self.mixer = mixer
        self.silenceAutoStopInterval = silenceAutoStopInterval
        self.backgroundWork = RecordingBackgroundWorkController(
            state: state,
            notifier: notifier,
            transcriptionRunner: transcriptionRunner,
            publicationRunner: publicationRunner)
        self.detector = detector ?? MeetingDetector(appDefinitions: {
            Dictionary(uniqueKeysWithValues: settings.meetingRules.map {
                ($0.bundleID, $0.appName)
            })
        })
        backgroundWork.onRecordingsChanged = { [weak self] in
            self?.refreshRecent()
        }
        notifier.isEnabled = enableSystemIntegrations
        if enableSystemIntegrations { notifier.configure() }
        // First-run users grant notifications in the wizard; only ask here once setup
        // is done (and the wizard has had its chance to sequence the prompt).
        if enableSystemIntegrations, settings.setupCompleted {
            Task { await Permissions.requestNotifications() }
        }
        notifier.onRecordAction = { [weak self] bundleID, audioMode in
            Task { @MainActor in
                guard let self,
                      let bundleID,
                      let meeting = self.detectedMeetings[bundleID]
                else {
                    return
                }
                await self.startRecording(
                    trigger: .meetingPrompt,
                    meeting: meeting,
                    audioMode: audioMode)
            }
        }
        notifier.onRetryAction = { [weak self] note in
            Task { @MainActor in self?.transcribeInBackground(session: RecordingSession(existingNote: note)) }
        }
        self.detector.onMeetingStart = { [weak self] meeting in
            Task { @MainActor in
                guard let self else { return }
                self.detectedMeetings[meeting.bundleID] = meeting
                guard case .idle = self.state.phase else { return }
                let policy = self.settings.meetingRules
                    .first { $0.bundleID == meeting.bundleID }?.policy ?? .ignore
                guard policy != .ignore else { return }
                switch policy {
                case .ignore:
                    break
                case .ask:
                    if !self.state.pendingMeetingPrompts.contains(meeting) {
                        self.state.pendingMeetingPrompts.append(meeting)
                    }
                    self.notifier.notify(
                        title: "Meeting detected: \(meeting.appName)",
                        body: "Choose which audio sources to record.",
                        category: "MEETING_START",
                        userInfo: ["meetingBundleID": meeting.bundleID])
                case .automatic:
                    self.notifier.notify(
                        title: "Meeting detected: \(meeting.appName)",
                        body: "Starting automatic recording.",
                        category: "INFO")
                    await self.startRecording(trigger: .meetingAutomatic, meeting: meeting)
                }
            }
        }
        self.detector.onMeetingEnd = { [weak self] meeting in
            Task { @MainActor in
                guard let self else { return }
                self.detectedMeetings.removeValue(forKey: meeting.bundleID)
                self.state.pendingMeetingPrompts.removeAll { $0.bundleID == meeting.bundleID }
                guard self.session?.sourceBundleID == meeting.bundleID,
                      self.state.phase == .starting || self.state.phase == .recording
                else { return }
                self.notifier.notify(title: "Meeting ended",
                                     body: "Recording stopped  -  transcribing in background.",
                                     category: "INFO")
                await self.stopRecording()
            }
        }
        if enableSystemIntegrations {
            self.detector.startPolling()
            hotKey = HotKey { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    switch self.state.phase {
                    case .idle: await self.startRecording(trigger: .hotKey)
                    case .starting, .recording: await self.stopRecording()
                    case .stopping: break
                    }
                }
            }
            applyHotKeySetting()
            NotificationCenter.default.addObserver(forName: Self.hotKeySettingChanged,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applyHotKeySetting() }
            }
        }
        refreshRecent()
        if enableSystemIntegrations {
            resumePendingPublications()
        }
    }

    private func applyHotKeySetting() {
        if settings.hotKeyEnabled {
            do { try hotKey?.register() }
            catch { state.lastError = error.localizedDescription }
        } else {
            hotKey?.unregister()
        }
    }

    func startRecording(
        trigger: RecordingTriggerKind = .manual,
        meeting: DetectedMeeting? = nil,
        audioMode: RecordingAudioMode? = nil
    ) async {
        guard case .idle = state.phase else { return }
        let selectedAudioMode = audioMode ?? settings.recordingAudioMode
        let associatedMeeting = meeting ?? inferredMeeting(for: trigger)
        if let associatedMeeting {
            state.pendingMeetingPrompts.removeAll {
                $0.bundleID == associatedMeeting.bundleID
            }
        }
        state.phase = .starting
        stopRequestedDuringStart = false
        let s = RecordingSession(
            root: settings.outputFolder,
            start: Date(),
            appName: associatedMeeting?.appName,
            bundleID: associatedMeeting?.bundleID,
            trigger: trigger)
        let r = recorderFactory()
        recorder = r
        session = s
        r.onStreamDied = { [weak self, weak r] error in
            Task { @MainActor in
                guard let self, let r, case .recording = self.state.phase, self.recorder === r else { return }
                self.notifier.notify(title: "Recording interrupted",
                                     body: "Audio saved up to this point.",
                                     category: "INFO", userInfo: ["recording": s.basename])
                self.state.lastError = error.localizedDescription
                await self.stopRecording()
            }
        }
        do {
            try await r.start(
                session: s,
                targetBundleID: associatedMeeting?.bundleID,
                audioMode: selectedAudioMode)
            state.phase = .recording
            if stopRequestedDuringStart {
                await stopRecording()
                return
            }
            state.elapsedSeconds = 0
            state.lastError = nil
            state.showPermissionHelp = false
            // .common mode: keep ticking while the menu is open (menu tracking pauses default-mode timers)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.handleRecordingTimerTick(at: Date())
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "MeetScribe is recording a meeting")
            notifier.notify(title: "Recording started",
                            body: recordingStartedMessage(
                                meeting: associatedMeeting,
                                audioMode: selectedAudioMode),
                            category: "INFO",
                            userInfo: ["recording": s.basename])
        } catch {
            recorder = nil
            session = nil
            stopRequestedDuringStart = false
            state.phase = .idle
            s.removeAssetDirectoryIfEmpty()
            state.lastError = "Could not start recording: \(error.localizedDescription)"
            // SCShareableContent fails without the Screen Recording grant; surface
            // a deep link to the right Privacy pane instead of a dead-end error.
            state.showPermissionHelp = (error as NSError).domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
                || error.localizedDescription.localizedCaseInsensitiveContains("permission")
                || error.localizedDescription.contains("No display found")
            notifier.notify(title: "Recording failed to start",
                            body: error.localizedDescription, category: "INFO")
        }
    }

    private func recordingStartedMessage(
        meeting: DetectedMeeting?,
        audioMode: RecordingAudioMode
    ) -> String {
        let source = audioMode == .systemOnly
            ? "Computer audio only."
            : "Computer and microphone audio."
        guard meeting != nil else { return source }
        return source + " Recording stops after "
            + "\(Self.meetingSilenceAutoStopMinutes) minutes without remote audio."
    }

    func handleRecordingTimerTick(at now: Date) async {
        guard state.phase == .recording,
              let recorder,
              let session
        else {
            return
        }
        state.elapsedSeconds = Int(now.timeIntervalSince(session.start))
        guard session.sourceBundleID != nil else { return }
        let lastActivity = recorder.lastMeetingAudioActivityAt ?? session.start
        guard now.timeIntervalSince(lastActivity) >= silenceAutoStopInterval else {
            return
        }
        await stopRecording()
        notifier.notify(
            title: "Meeting appears to have ended",
            body: "No remote meeting audio for "
                + "\(Self.meetingSilenceAutoStopMinutes) minutes. Recording stopped.",
            category: "INFO")
    }

    func stopRecording() async {
        if case .starting = state.phase {
            stopRequestedDuringStart = true
            return
        }
        guard case .recording = state.phase, let r = recorder, let s = session else { return }
        state.phase = .stopping
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        do {
            try await r.stop()
            if let warning = r.sourceWarning { state.lastError = warning }
            try await mixer(s)
            try RecordingManifestStore.update(at: s.manifestURL) { manifest in
                manifest.endedAt = Date()
                manifest.lifecycle = .recorded
            }
            notifier.notify(title: "Recording saved",
                            body: "Transcribing in background…",
                            category: "INFO", userInfo: ["notePath": s.noteURL.path])
            transcribeInBackground(session: s)
        } catch {
            state.lastError = RecordingBackgroundWorkController.failureDescription(
                error,
                session: s,
                endedAt: Date())
            notifier.notify(title: "Recording failed", body: "Audio may be recoverable in Recent recordings.",
                            category: "TRANSCRIBE_FAILED", userInfo: ["notePath": s.noteURL.path])
        }
        recorder = nil
        session = nil
        stopRequestedDuringStart = false
        state.phase = .idle
        refreshRecent()
    }

    private func inferredMeeting(
        for trigger: RecordingTriggerKind
    ) -> DetectedMeeting? {
        switch trigger {
        case .manual, .hotKey:
            let eligibleMeetings = detectedMeetings.values.filter { meeting in
                settings.meetingRules
                    .first { $0.bundleID == meeting.bundleID }?
                    .policy != .ignore
            }
            guard eligibleMeetings.count == 1 else { return nil }
            return eligibleMeetings.first
        case .meetingPrompt, .meetingAutomatic:
            return nil
        }
    }

    /// Runs Whisper and optional transcript processing off the main actor; the app stays usable
    /// (and can record again) while transcription runs.
    func transcribeInBackground(session s: RecordingSession) {
        backgroundWork.transcribe(
            session: s,
            configuration: RecordingTranscriptionConfiguration(
                mlxWhisperPath: settings.mlxWhisperPath,
                whisperModel: settings.whisperModel,
                agentConfiguration: settings.agentConfiguration,
                retentionConfiguration: settings.retentionConfiguration),
            destinationConfiguration: settings.destinationConfiguration)
    }

    func publishInBackground(
        session s: RecordingSession,
        configuration: DestinationConfiguration? = nil
    ) {
        let selectedConfiguration = configuration ?? settings.destinationConfiguration
        backgroundWork.publish(
            session: s,
            configuration: selectedConfiguration)
    }

    func retryPublication(note: URL) {
        publishInBackground(session: RecordingSession(existingNote: note))
    }

    private func resumePendingPublications() {
        let configuration = settings.destinationConfiguration
        guard configuration.hasEnabledDestination else { return }
        let recordings: [RecordingRecord]
        do {
            recordings = try RecordingLibrary.recordings(
                root: settings.outputFolder,
                limit: nil)
        } catch {
            state.lastError = "Could not recover recordings: \(error.localizedDescription)"
            return
        }
        for recording in recordings where recording.hasTranscript {
            let session = RecordingSession(existingNote: recording.noteURL)
            if PublicationService.needsResume(session: session, configuration: configuration) {
                publishInBackground(session: session, configuration: configuration)
            }
        }
    }

    /// Quit path: stop a live recording, then wait for in-flight transcriptions
    /// (bounded courtesy wait) before terminating.
    func quitAfterPendingWork() async {
        if state.phase == .starting || state.phase == .recording { await stopRecording() }
        let stopDeadline = Date().addingTimeInterval(30)
        while state.phase != .idle, Date() < stopDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let deadline = Date().addingTimeInterval(300)
        while state.transcribingCount > 0 || state.publishingCount > 0, Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        NSApplication.shared.terminate(nil)
    }

    func retryTranscription(note: URL) {
        transcribeInBackground(session: RecordingSession(existingNote: note))
    }

    func moveToTrash(_ recording: RecordingRecord) {
        guard !backgroundWork.isWorking(on: recording.assetDir) else {
            state.lastError = "Wait for transcription or publishing to finish before moving this recording to Trash."
            return
        }
        var items = [recording.assetDir]
        if recording.hasTranscript { items.append(recording.noteURL) }
        NSWorkspace.shared.recycle(items) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.state.lastError = "Could not move recording to Trash: \(error.localizedDescription)" }
                self?.refreshRecent()
            }
        }
    }

    func clearError() {
        backgroundWork.clearError()
        state.showPermissionHelp = false
    }

    func recordTranscriptionFailure(_ description: String, for key: String) {
        backgroundWork.recordTranscriptionFailure(description, for: key)
    }

    func clearTranscriptionFailure(for key: String) {
        backgroundWork.clearTranscriptionFailure(for: key)
    }

    func refreshRecent() {
        do {
            let recordings = try RecordingLibrary.recordings(
                root: settings.outputFolder,
                limit: nil)
            try RetentionService.applyAgePolicies(
                recordings: recordings,
                configuration: settings.retentionConfiguration)
            state.recentRecordings = Array(recordings.prefix(5))
        } catch {
            let recoveryError = "Could not recover recordings: \(error.localizedDescription)"
            if let currentError = state.lastError,
               !currentError.contains(recoveryError)
            {
                state.lastError = "\(currentError) \(recoveryError)"
            } else {
                state.lastError = recoveryError
            }
        }
    }

}
