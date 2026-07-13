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

    init(state: AppState) {
        self.state = state
        notifier.setup()
        notifier.onRecordAction = { [weak self] in Task { await self?.startRecording() } }
        notifier.onRetryAction = { [weak self] folder in
            Task { @MainActor in self?.transcribeInBackground(session: RecordingSession(existingFolder: folder, start: Date())) }
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
        refreshRecent()
    }

    func startRecording() async {
        guard case .idle = state.phase else { return }
        let s = RecordingSession(root: settings.outputFolder, start: Date(), appName: detectedApp)
        let r = AudioRecorder()
        do {
            try await r.start(session: s)
            recorder = r
            session = s
            let start = s.start
            state.phase = .recording
            state.elapsedSeconds = 0
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
                            body: s.folder.lastPathComponent, category: "INFO",
                            userInfo: ["folder": s.folder.path])
        } catch {
            state.lastError = "Could not start recording: \(error.localizedDescription)"
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
                            body: "\(s.folder.lastPathComponent)  -  transcribing in background…",
                            category: "INFO", userInfo: ["folder": s.folder.path])
            transcribeInBackground(session: s)
        } catch {
            state.lastError = error.localizedDescription
            notifier.notify(title: "Recording failed", body: error.localizedDescription,
                            category: "TRANSCRIBE_FAILED", userInfo: ["folder": s.folder.path])
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
                let (mic, sys) = (tracks[0], tracks[1])

                let raw = try JSONEncoder().encode(["mic": mic, "system": sys])
                try raw.write(to: s.transcriptJSON, options: .atomic)

                let dur = max(mic.last?.end ?? 0, sys.last?.end ?? 0)
                var md = TranscriptFormatter.format(mic: mic, system: sys, header: .init(
                    date: RecordingSession.headerDateFormatter.string(from: s.start),
                    app: s.appName ?? s.folder.lastPathComponent.components(separatedBy: "_").last ?? "manual",
                    duration: TranscriptFormatter.hms(dur),
                    model: settings.whisperModel, cleanedByClaude: false))
                try md.write(to: s.transcriptMD, atomically: true, encoding: .utf8)
                notifier.notify(title: "Transcript ready",
                                body: s.folder.lastPathComponent, category: "INFO",
                                userInfo: ["folder": s.folder.path])

                if settings.claudeCleanupEnabled, let result = ClaudeCleaner.clean(md) {
                    md = result.markdown
                    try md.write(to: s.transcriptMD, atomically: true, encoding: .utf8)
                    // Rename folder to <date>_<time>_<topic> now that we know the topic.
                    var finalFolder = s.folder
                    if let slug = result.topicSlug {
                        let stamp = s.folder.lastPathComponent.split(separator: "_").prefix(2).joined(separator: "_")
                        let dest = s.folder.deletingLastPathComponent().appendingPathComponent("\(stamp)_\(slug)")
                        if dest != s.folder, !FileManager.default.fileExists(atPath: dest.path),
                           (try? FileManager.default.moveItem(at: s.folder, to: dest)) != nil {
                            finalFolder = dest
                        }
                    }
                    notifier.notify(title: "Transcript cleaned by Claude",
                                    body: finalFolder.lastPathComponent, category: "INFO",
                                    userInfo: ["folder": finalFolder.path])
                }
            } catch {
                notifier.notify(title: "Transcription failed",
                                body: "Audio is safe. Retry? (\(error.localizedDescription))",
                                category: "TRANSCRIBE_FAILED",
                                userInfo: ["folder": s.folder.path])
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

    func refreshRecent() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: settings.outputFolder,
                                                includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        state.recentRecordings = Array(dirs.prefix(5))
    }
}
