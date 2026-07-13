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

    init(state: AppState) {
        self.state = state
        notifier.setup()
        notifier.onRecordAction = { [weak self] in Task { await self?.startRecording() } }
        notifier.onStopAction = { [weak self] in Task { await self?.stopRecording() } }
        notifier.onRetryAction = { [weak self] folder in Task { await self?.retryTranscription(folder: folder) } }
        detector.onMeetingStart = { [weak self] meeting in
            Task { @MainActor in
                guard let self, case .idle = self.state.phase else { return }
                self.detectedApp = meeting.appName
                self.notifier.notify(title: "Meeting detected: \(meeting.appName)",
                                     body: "Want to record it?", category: "MEETING_START")
            }
        }
        detector.onMeetingEnd = { [weak self] _ in
            Task { @MainActor in
                guard let self, case .recording = self.state.phase else { return }
                self.notifier.notify(title: "Meeting ended",
                                     body: "Stop the recording?", category: "MEETING_END")
                if let secs = self.settings.autoStopSeconds {
                    try? await Task.sleep(for: .seconds(secs))
                    if case .recording = self.state.phase { await self.stopRecording() }
                }
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
            state.phase = .recording(start: Date())
        } catch {
            state.lastError = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard case .recording = state.phase, let r = recorder, let s = session else { return }
        state.phase = .transcribing
        do {
            try await r.stop()
            if let warning = r.sourceWarning { state.lastError = warning }
            try await AudioRecorder.mix(session: s)
            try await transcribe(session: s)
        } catch {
            state.lastError = error.localizedDescription
            notifier.notify(title: "Transcription failed", body: "Audio is safe. Retry?",
                            category: "TRANSCRIBE_FAILED", userInfo: ["folder": s.folder.path])
        }
        recorder = nil
        session = nil
        detectedApp = nil
        state.phase = .idle
        refreshRecent()
    }

    private func transcribe(session s: RecordingSession) async throws {
        let settings = self.settings
        let result = try await Task.detached(priority: .userInitiated) { () -> String in
            let t = Transcriber(mlxWhisperPath: settings.mlxWhisperPath, model: settings.whisperModel)
            let mic = FileManager.default.fileExists(atPath: s.micURL.path) ? try t.transcribe(s.micURL) : []
            let sys = FileManager.default.fileExists(atPath: s.systemURL.path) ? try t.transcribe(s.systemURL) : []

            let raw = try JSONEncoder().encode(["mic": mic, "system": sys])
            try raw.write(to: s.transcriptJSON)

            let dur = max(mic.last?.end ?? 0, sys.last?.end ?? 0)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            var md = TranscriptFormatter.format(mic: mic, system: sys, header: .init(
                date: fmt.string(from: s.start),
                app: s.folder.lastPathComponent.components(separatedBy: "_").last ?? "manual",
                duration: TranscriptFormatter.hms(dur),
                model: settings.whisperModel, cleanedByClaude: false))
            if settings.claudeCleanupEnabled, let polished = ClaudeCleaner.clean(md) {
                md = polished
            }
            return md
        }.value
        try result.write(to: s.transcriptMD, atomically: true, encoding: .utf8)
        notifier.notify(title: "Transcript ready", body: s.folder.lastPathComponent, category: "MEETING_END")
    }

    func retryTranscription(folder: URL) async {
        state.phase = .transcribing
        do { try await transcribe(session: RecordingSession(existingFolder: folder, start: Date())) }
        catch { state.lastError = error.localizedDescription }
        state.phase = .idle
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
