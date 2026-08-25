import Foundation

struct RecordingTranscriptionConfiguration: Sendable {
    let mlxWhisperPath: String
    let whisperModel: String
    let agentConfiguration: AgentConfiguration
    let retentionConfiguration: RetentionConfiguration

    init(
        mlxWhisperPath: String,
        whisperModel: String,
        agentConfiguration: AgentConfiguration,
        retentionConfiguration: RetentionConfiguration = RetentionConfiguration()
    ) {
        self.mlxWhisperPath = mlxWhisperPath
        self.whisperModel = whisperModel
        self.agentConfiguration = agentConfiguration
        self.retentionConfiguration = retentionConfiguration
    }
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

struct RecordingFinalizerRunner: Sendable {
    let move: @Sendable (_ session: RecordingSession, _ topicSlug: String) throws -> URL

    static let live = RecordingFinalizerRunner {
        try RecordingFinalizer.move($0, toTopicSlug: $1)
    }
}

enum RecordingTranscriptionService {
    static func run(
        session: RecordingSession,
        configuration: RecordingTranscriptionConfiguration,
        trackTranscriber: RecordingTrackTranscriber = .live,
        finalizer: RecordingFinalizerRunner = .live
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
        let markdown = TranscriptFormatter.format(
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
                    let processedMarkdown = TranscriptFormatter.markProcessed(
                        result.markdown,
                        by: processor.id)
                    finalNote = try finalizer.move(session, result.topicSlug)
                    try processedMarkdown.write(
                        to: finalNote,
                        atomically: true,
                        encoding: .utf8)
                    let processedSession = RecordingSession(
                        existingNote: finalNote,
                        start: session.start)
                    try processedSession.secureFile(finalNote)
                    processorID = processor.id
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
        do {
            try RetentionService.applyPostTranscription(
                session: finalSession,
                configuration: configuration.retentionConfiguration)
        } catch {
            let retentionWarning = "Retention cleanup failed: \(error.localizedDescription)"
            processingWarning = [processingWarning, retentionWarning]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return RecordingTranscriptionResult(
            finalSession: finalSession,
            processingWarning: processingWarning,
            processorID: processorID)
    }
}
