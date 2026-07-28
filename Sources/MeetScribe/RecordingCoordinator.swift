import Foundation
import AppKit

@MainActor
final class RecordingCoordinator: ObservableObject {
    let state: AppState
    let notifier = Notifier()
    let detector = MeetingDetector()
    private var recorder: (any AudioRecording)?
    private var session: RecordingSession?
    private var detectedMeeting: DetectedMeeting?
    private var settings = Settings()
    private var elapsedTimer: Timer?
    private var sleepActivity: NSObjectProtocol?
    private var hotKey: HotKey?
    private var stopRequestedDuringStart = false
    private var activeTranscriptions: Set<String> = []
    private let recorderFactory: () -> any AudioRecording
    private let mixer: (RecordingSession) async throws -> Void

    static let hotKeySettingChanged = Notification.Name("meetscribe.hotKeySettingChanged")

    init(
        state: AppState,
        recorderFactory: @escaping () -> any AudioRecording = { AudioRecorder() },
        mixer: @escaping (RecordingSession) async throws -> Void = { try await AudioRecorder.mix(session: $0) },
        enableSystemIntegrations: Bool = true
    ) {
        self.state = state
        self.recorderFactory = recorderFactory
        self.mixer = mixer
        notifier.isEnabled = enableSystemIntegrations
        if enableSystemIntegrations { notifier.configure() }
        // First-run users grant notifications in the wizard; only ask here once setup
        // is done (and the wizard has had its chance to sequence the prompt).
        if enableSystemIntegrations, settings.setupCompleted {
            Task { await Permissions.requestNotifications() }
        }
        notifier.onRecordAction = { [weak self] in Task { await self?.startRecording() } }
        notifier.onRetryAction = { [weak self] note in
            Task { @MainActor in self?.transcribeInBackground(session: RecordingSession(existingNote: note)) }
        }
        detector.onMeetingStart = { [weak self] meeting in
            Task { @MainActor in
                guard let self, case .idle = self.state.phase else { return }
                self.detectedMeeting = meeting
                self.notifier.notify(title: "Meeting detected: \(meeting.appName)",
                                     body: "Want to record it?", category: "MEETING_START")
            }
        }
        detector.onMeetingEnd = { [weak self] meeting in
            Task { @MainActor in
                guard let self else { return }
                if self.detectedMeeting == meeting { self.detectedMeeting = nil }
                guard self.session?.appName == meeting.appName,
                      self.state.phase == .starting || self.state.phase == .recording
                else { return }
                self.notifier.notify(title: "Meeting ended",
                                     body: "Recording stopped  -  transcribing in background.",
                                     category: "INFO")
                await self.stopRecording()
            }
        }
        if enableSystemIntegrations {
            detector.startPolling()
            hotKey = HotKey { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    switch self.state.phase {
                    case .idle: await self.startRecording()
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
    }

    private func applyHotKeySetting() {
        if settings.hotKeyEnabled {
            do { try hotKey?.register() }
            catch { state.lastError = error.localizedDescription }
        } else {
            hotKey?.unregister()
        }
    }

    func startRecording() async {
        guard case .idle = state.phase else { return }
        state.phase = .starting
        stopRequestedDuringStart = false
        let meeting = detectedMeeting
        let s = RecordingSession(root: settings.outputFolder, start: Date(), appName: meeting?.appName)
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
            try await r.start(session: s, targetBundleID: meeting?.bundleID)
            state.phase = .recording
            if stopRequestedDuringStart {
                await stopRecording()
                return
            }
            let start = s.start
            state.elapsedSeconds = 0
            state.lastError = nil
            state.showPermissionHelp = false
            // .common mode: keep ticking while the menu is open (menu tracking pauses default-mode timers)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.state.elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            elapsedTimer = timer
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "MeetScribe is recording a meeting")
            notifier.notify(title: "Recording started",
                            body: meeting == nil ? "Manual capture includes all system audio." : "Meeting audio capture started.",
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
                            body: error.localizedDescription, category: "MEETING_START")
        }
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
            notifier.notify(title: "Recording saved",
                            body: "Transcribing in background…",
                            category: "INFO", userInfo: ["recording": s.basename])
            transcribeInBackground(session: s)
        } catch {
            state.lastError = error.localizedDescription
            notifier.notify(title: "Recording failed", body: "Audio may be recoverable in Recent recordings.",
                            category: "TRANSCRIBE_FAILED", userInfo: ["recording": s.basename])
        }
        recorder = nil
        session = nil
        stopRequestedDuringStart = false
        state.phase = .idle
        refreshRecent()
    }

    /// Runs whisper + claude cleanup off the main actor; the app stays usable
    /// (and can record again) while transcription runs.
    func transcribeInBackground(session s: RecordingSession) {
        let key = s.assetDir.standardizedFileURL.path
        guard activeTranscriptions.insert(key).inserted else { return }
        state.transcribingCount = activeTranscriptions.count
        let whisperPath = settings.mlxWhisperPath
        let whisperModel = settings.whisperModel
        let cleanupEnabled = settings.claudeCleanupEnabled
        let notifier = self.notifier
        Task.detached(priority: .utility) { [weak self] in
            do {
                let t = Transcriber(mlxWhisperPath: whisperPath, model: whisperModel)
                let tracks = try t.transcribe(mic: s.micURL, system: s.systemURL)
                let (rawMic, sys) = (tracks.mic, tracks.system)

                let raw = try JSONEncoder().encode(["mic": rawMic, "system": sys])
                try raw.write(to: s.transcriptJSON, options: .atomic)
                try s.secureFile(s.transcriptJSON)

                // Without headphones the mic picks up the speakers; drop that echo
                // so remote speech isn't duplicated as "Me".
                let mic = TranscriptFormatter.suppressEcho(mic: rawMic, system: sys)

                let dur = max(mic.last?.end ?? 0, sys.last?.end ?? 0)
                // Provisional app label: the appName, or (on retry, where appName is nil)
                // the slug portion of the note basename after the `yyyy-MM-dd-` prefix.
                let appLabel = s.appName ?? String(s.basename.dropFirst(s.datePart.count + 1))
                var md = TranscriptFormatter.format(mic: mic, system: sys, header: .init(
                    date: RecordingSession.headerDateFormatter.string(from: s.start),
                    app: appLabel.isEmpty ? "manual" : appLabel,
                    duration: TranscriptFormatter.hms(dur),
                    model: whisperModel, cleanedByClaude: false))
                try md.write(to: s.transcriptMD, atomically: true, encoding: .utf8)
                try s.secureFile(s.transcriptMD)

                var finalNote = s.noteURL
                var cleanupWarning: String?
                if cleanupEnabled {
                    do {
                        if let result = try ClaudeCleaner.clean(md) {
                            md = TranscriptFormatter.markCleaned(result.markdown)
                            try md.write(to: s.transcriptMD, atomically: true, encoding: .utf8)
                            try s.secureFile(s.transcriptMD)
                            if let slug = result.topicSlug {
                                finalNote = try RecordingFinalizer.move(s, toTopicSlug: slug)
                            }
                        }
                    } catch {
                        cleanupWarning = error.localizedDescription
                    }
                }
                if let cleanupWarning {
                    notifier.notify(title: "Claude cleanup skipped",
                                    body: cleanupWarning, category: "INFO",
                                    userInfo: ["recording":
                                        finalNote.deletingPathExtension().lastPathComponent])
                    await MainActor.run { [weak self] in self?.state.lastError = cleanupWarning }
                }
                notifier.notify(title: "Transcript ready",
                                body: "Your transcript is ready.", category: "INFO",
                                userInfo: ["recording":
                                    finalNote.deletingPathExtension().lastPathComponent])
                if cleanupEnabled, cleanupWarning == nil, finalNote != s.noteURL {
                    notifier.notify(title: "Transcript cleaned by Claude",
                                    body: "Cleanup completed.", category: "INFO",
                                    userInfo: ["recording":
                                        finalNote.deletingPathExtension().lastPathComponent])
                }
            } catch {
                notifier.notify(title: "Transcription failed",
                                body: "Audio is safe. Retry from Recent recordings.",
                                category: "TRANSCRIBE_FAILED",
                                userInfo: ["recording": s.basename])
                await MainActor.run { [weak self] in
                    self?.state.lastError = "Transcription failed: \(error.localizedDescription)"
                }
            }
            await MainActor.run { [weak self] in
                self?.activeTranscriptions.remove(key)
                self?.state.transcribingCount = self?.activeTranscriptions.count ?? 0
                self?.refreshRecent()
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
        while state.transcribingCount > 0, Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        NSApplication.shared.terminate(nil)
    }

    func retryTranscription(note: URL) {
        transcribeInBackground(session: RecordingSession(existingNote: note))
    }

    func moveToTrash(_ recording: RecordingRecord) {
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
        state.lastError = nil
        state.showPermissionHelp = false
    }

    func refreshRecent() {
        state.recentRecordings = RecordingLibrary.recordings(root: settings.outputFolder)
    }
}
