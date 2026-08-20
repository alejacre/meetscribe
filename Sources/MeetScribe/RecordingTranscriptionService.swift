import Foundation

struct RecordingTranscriptionConfiguration: Sendable {
    let mlxWhisperPath: String
    let whisperModel: String
    let agentConfiguration: AgentConfiguration
}

struct RecordingTranscriptionResult: Sendable {
    let finalSession: RecordingSession
    let processingWarning: String?
    let processorID: String?
}

struct RecordingTrackTranscriber: Sendable {
    let transcribe: @Sendable (
        _ session: RecordingSession,
        _ configuration: RecordingTranscriptionConfiguration
    ) throws -> TranscriptionTracks

    static let live = RecordingTrackTranscriber { session, configuration in
        try Transcriber(
            mlxWhisperPath: configuration.mlxWhisperPath,
            model: configuration.whisperModel)
            .transcribe(mic: session.micURL, system: session.systemURL)
    }
}

struct RecordingTranscriptionRunner: Sendable {
    let run: @Sendable (
        _ session: RecordingSession,
        _ configuration: RecordingTranscriptionConfiguration
    ) throws -> RecordingTranscriptionResult

    static let live = RecordingTranscriptionRunner {
        try RecordingTranscriptionService.run(session: $0, configuration: $1)
    }
}

enum RecordingTranscriptionService {
    static func run(
        session: RecordingSession,
        configuration: RecordingTranscriptionConfiguration,
        trackTranscriber: RecordingTrackTranscriber = .live
    ) throws -> RecordingTranscriptionResult {
        try session.ensureManifest()
        try RecordingManifestStore.update(at: session.manifestURL) { manifest in
            manifest.lifecycle = .transcribing
        }

        let tracks = try trackTranscriber.transcribe(session, configuration)
        let rawMic = tracks.mic
        let system = tracks.system

        let raw = try JSONEncoder().encode(["mic": rawMic, "system": system])
        try raw.write(to: session.transcriptJSON, options: .atomic)
        try session.secureFile(session.transcriptJSON)

        let mic = TranscriptFormatter.suppressEcho(mic: rawMic, system: system)
        let duration = max(mic.last?.end ?? 0, system.last?.end ?? 0)
        let appLabel = session.appName
            ?? String(session.basename.dropFirst(session.datePart.count + 1))
        var markdown = TranscriptFormatter.format(
            mic: mic,
            system: system,
            header: .init(
                date: RecordingSession.headerDateFormatter.string(from: session.start),
                app: appLabel.isEmpty ? "manual" : appLabel,
                duration: TranscriptFormatter.hms(duration),
                model: configuration.whisperModel,
                cleanedByClaude: false))
        try markdown.write(
            to: session.transcriptMD,
            atomically: true,
            encoding: .utf8)
        try session.secureFile(session.transcriptMD)

        var finalNote = session.noteURL
        var processingWarning: String?
        var processorID: String?
        if let processor = TranscriptProcessorFactory.make(
            configuration: configuration.agentConfiguration)
        {
            do {
                if let result = try processor.process(markdown) {
                    processorID = processor.id
                    markdown = TranscriptFormatter.markProcessed(
                        result.markdown,
                        by: processor.id)
                    try markdown.write(
                        to: session.transcriptMD,
                        atomically: true,
                        encoding: .utf8)
                    try session.secureFile(session.transcriptMD)
                    if let slug = result.topicSlug {
                        finalNote = try RecordingFinalizer.move(
                            session,
                            toTopicSlug: slug)
                    }
                }
            } catch {
                processingWarning = error.localizedDescription
            }
        }

        let finalSession = RecordingSession(
            existingNote: finalNote,
            start: session.start)
        try RecordingManifestStore.update(at: finalSession.manifestURL) { manifest in
            manifest.lifecycle = .ready
            manifest.transcript = TranscriptRunMetadata(
                completedAt: Date(),
                model: configuration.whisperModel,
                processorID: processorID)
        }
        return RecordingTranscriptionResult(
            finalSession: finalSession,
            processingWarning: processingWarning,
            processorID: processorID)
    }
}
