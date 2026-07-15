import Foundation
import AppKit

@MainActor
final class RecordingCoordinator: ObservableObject {
    let state: AppState
    let notifier = Notifier()
    let detector = MeetingDetector()
    private var recorder: AudioRecorder?
    private var session: RecordingSession?
    private var detectedApp: String?
    private var settings = Settings()
    private var elapsedTimer: Timer?
    private var sleepActivity: NSObjectProtocol?
    private var hotKey: HotKey?

    static let hotKeySettingChanged = Notification.Name("meetscribe.hotKeySettingChanged")

    init(state: AppState) {
        self.state = state
        notifier.configure()
        // First-run users grant notifications in the wizard; only ask here once setup
        // is done (and the wizard has had its chance to sequence the prompt).
        if settings.setupCompleted {
            Task { await Permissions.requestNotifications() }
        }
        notifier.onRecordAction = { [weak self] in Task { await self?.startRecording() } }
        notifier.onRetryAction = { [weak self] note in
            Task { @MainActor in self?.transcribeInBackground(session: RecordingSession(existingNote: note)) }
        }
        detector.onMeetingStart = { [weak self] meeting in
            Task { @MainActor in
                guard let self, case .idle = self.state.phase else { return }
                self.detectedApp = meeting.appName
                self.notifier.notify(title: "Meeting detected: \(meeting.appName)",
                                     body: "Want to record it?", category: "MEETING_START")
            }
        }
        detector.onMeetingEnd = { [weak self] meeting in
            Task { @MainActor in
                guard let self, case .recording = self.state.phase else { return }
                self.notifier.notify(title: "Meeting ended",
                                     body: "Recording stopped  -  transcribing in background.",
                                     category: "INFO")
                await self.stopRecording()
            }
        }
        detector.startPolling()
        hotKey = HotKey { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                switch self.state.phase {
                case .idle: await self.startRecording()
                case .recording: await self.stopRecording()
                }
            }
        }
        applyHotKeySetting()
        NotificationCenter.default.addObserver(forName: Self.hotKeySettingChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyHotKeySetting() }
        }
        refreshRecent()
    }

    private func applyHotKeySetting() {
        if settings.hotKeyEnabled { hotKey?.register() } else { hotKey?.unregister() }
    }

    func startRecording() async {
        guard case .idle = state.phase else { return }
        // Claim the phase BEFORE the first await: two rapid invocations would
        // otherwise both pass the guard and spawn two recorders.
        state.phase = .recording
        let s = RecordingSession(root: settings.outputFolder, start: Date(), appName: detectedApp)
        let r = AudioRecorder()
        do {
            try await r.start(session: s)
            r.onStreamDied = { [weak self] error in
                Task { @MainActor in
                    guard let self, case .recording = self.state.phase, self.recorder === r else { return }
                    self.notifier.notify(title: "Recording interrupted",
                                         body: "Audio saved up to this point. (\(error.localizedDescription))",
                                         category: "INFO", userInfo: ["note": s.noteURL.path])
                    await self.stopRecording()
                }
            }
            recorder = r
            session = s
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
                            body: s.basename, category: "INFO",
                            userInfo: ["note": s.noteURL.path])
        } catch {
            state.phase = .idle
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
        guard case .recording = state.phase, let r = recorder, let s = session else { return }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        state.phase = .idle
        recorder = nil
        session = nil
        detectedApp = nil
        do {
            try await r.stop()
            if let warning = r.sourceWarning { state.lastError = warning }
            try await AudioRecorder.mix(session: s)
            notifier.notify(title: "Recording saved",
                            body: "\(s.basename)  -  transcribing in background…",
                            category: "INFO", userInfo: ["note": s.noteURL.path])
            transcribeInBackground(session: s)
        } catch {
            state.lastError = error.localizedDescription
            notifier.notify(title: "Recording failed", body: error.localizedDescription,
                            category: "TRANSCRIBE_FAILED", userInfo: ["note": s.noteURL.path])
        }
        refreshRecent()
    }

    /// Runs whisper + claude cleanup off the main actor; the app stays usable
    /// (and can record again) while transcription runs.
    func transcribeInBackground(session s: RecordingSession) {
        state.transcribingCount += 1
        let settings = self.settings
        let notifier = self.notifier
        Task.detached(priority: .utility) { [weak self] in
            do {
                let t = Transcriber(mlxWhisperPath: settings.mlxWhisperPath, model: settings.whisperModel)
                let tracks = try t.transcribe([s.micURL, s.systemURL])
                let (rawMic, sys) = (tracks[0], tracks[1])

                let raw = try JSONEncoder().encode(["mic": rawMic, "system": sys])
                try raw.write(to: s.transcriptJSON, options: .atomic)

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
                    model: settings.whisperModel, cleanedByClaude: false))
                try md.write(to: s.transcriptMD, atomically: true, encoding: .utf8)
                notifier.notify(title: "Transcript ready",
                                body: s.basename, category: "INFO",
                                userInfo: ["note": s.noteURL.path])

                if settings.claudeCleanupEnabled, let result = ClaudeCleaner.clean(md) {
                    // The prompt tells Claude not to touch the meta comment, so it still
                    // reads cleaned=false  -  patch it here.
                    md = TranscriptFormatter.markCleaned(result.markdown)
                    try md.write(to: s.transcriptMD, atomically: true, encoding: .utf8)
                    // Rename note + asset dir to <date>-<topic> now that we know the topic.
                    var finalNote = s.noteURL
                    if let slug = result.topicSlug {
                        let root = s.noteURL.deletingLastPathComponent()
                        var dest = root.appendingPathComponent("\(s.datePart)-\(slug).md")
                        var n = 2
                        while dest != s.noteURL, FileManager.default.fileExists(atPath: dest.path) {
                            dest = root.appendingPathComponent("\(s.datePart)-\(slug)-\(n).md"); n += 1
                        }
                        if dest != s.noteURL,
                           (try? FileManager.default.moveItem(at: s.noteURL, to: dest)) != nil {
                            finalNote = dest
                            // Keep the asset dir name in sync with the note (best effort).
                            let assetDest = s.assetDir.deletingLastPathComponent()
                                .appendingPathComponent(dest.deletingPathExtension().lastPathComponent, isDirectory: true)
                            if !FileManager.default.fileExists(atPath: assetDest.path) {
                                try? FileManager.default.moveItem(at: s.assetDir, to: assetDest)
                            }
                        }
                    }
                    notifier.notify(title: "Transcript cleaned by Claude",
                                    body: finalNote.deletingPathExtension().lastPathComponent, category: "INFO",
                                    userInfo: ["note": finalNote.path])
                }
            } catch {
                notifier.notify(title: "Transcription failed",
                                body: "Audio is safe. Retry? (\(error.localizedDescription))",
                                category: "TRANSCRIBE_FAILED",
                                userInfo: ["note": s.noteURL.path])
                await MainActor.run { [weak self] in
                    self?.state.lastError = "Transcription failed: \(error.localizedDescription)"
                }
            }
            await MainActor.run { [weak self] in
                self?.state.transcribingCount -= 1
                self?.refreshRecent()
            }
        }
    }

    /// Quit path: stop a live recording, then wait for in-flight transcriptions
    /// (bounded courtesy wait) before terminating.
    func quitAfterPendingWork() async {
        if case .recording = state.phase { await stopRecording() }
        let deadline = Date().addingTimeInterval(300)
        while state.transcribingCount > 0, Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        NSApplication.shared.terminate(nil)
    }

    func retryTranscription(note: URL) {
        transcribeInBackground(session: RecordingSession(existingNote: note))
    }

    func clearError() {
        state.lastError = nil
        state.showPermissionHelp = false
    }

    func refreshRecent() {
        // Recent = MEETSCRIBE notes only, not the vault's hand-curated meeting notes.
        // A recording note is the one that owns a `.assets/<basename>/` sidecar dir.
        let fm = FileManager.default
        let notes = (try? fm.contentsOfDirectory(at: settings.outputFolder,
                                                 includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }
            .filter { fm.fileExists(atPath: RecordingSession(existingNote: $0).assetDir.path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        state.recentRecordings = Array(notes.prefix(5))
    }
}
