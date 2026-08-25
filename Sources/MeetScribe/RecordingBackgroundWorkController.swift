import Foundation

@MainActor
final class RecordingBackgroundWorkController {
    private let state: AppState
    private let notifier: Notifier
    private let transcriptionRunner: RecordingTranscriptionRunner
    private let publicationRunner: RecordingPublicationRunner
    private var activeTranscriptions: Set<String> = []
    private var activePublications: Set<String> = []
    private var lastTranscriptionFailure: (key: String, message: String)?
    private var lastPublicationFailure: (key: String, message: String)?

    var onRecordingsChanged: (() -> Void)?

    init(
        state: AppState,
        notifier: Notifier,
        transcriptionRunner: RecordingTranscriptionRunner,
        publicationRunner: RecordingPublicationRunner
    ) {
        self.state = state
        self.notifier = notifier
        self.transcriptionRunner = transcriptionRunner
        self.publicationRunner = publicationRunner
    }

    func transcribe(
        session: RecordingSession,
        configuration: RecordingTranscriptionConfiguration,
        destinationConfiguration: DestinationConfiguration
    ) {
        let key = session.assetDir.standardizedFileURL.path
        guard activeTranscriptions.insert(key).inserted else { return }
        state.transcribingCount = activeTranscriptions.count
        let runner = transcriptionRunner
        Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try runner.run(session, configuration)
                await MainActor.run { [weak self] in
                    self?.finishTranscription(
                        result: result,
                        key: key,
                        destinationConfiguration: destinationConfiguration)
                }
            } catch {
                let description = Self.failureDescription(
                    error,
                    session: session)
                await MainActor.run { [weak self] in
                    self?.finishTranscriptionFailure(
                        description,
                        session: session,
                        key: key)
                }
            }
        }
    }

    func publish(
        session: RecordingSession,
        configuration: DestinationConfiguration
    ) {
        guard configuration.hasEnabledDestination else { return }
        let key = session.assetDir.standardizedFileURL.path
        guard activePublications.insert(key).inserted else { return }
        state.publishingCount = activePublications.count
        let runner = publicationRunner
        Task.detached(priority: .utility) { [weak self] in
            let results = runner.run(session, configuration)
            await MainActor.run { [weak self] in
                self?.finishPublication(
                    results: results,
                    session: session,
                    key: key)
            }
        }
    }

    func isWorking(on assetDirectory: URL) -> Bool {
        let key = assetDirectory.standardizedFileURL.path
        return activeTranscriptions.contains(key)
            || activePublications.contains(key)
    }

    func clearError() {
        state.lastError = nil
        lastTranscriptionFailure = nil
        lastPublicationFailure = nil
    }

    func recordTranscriptionFailure(_ description: String, for key: String) {
        let message = "Transcription failed: \(description)"
        lastTranscriptionFailure = (key, message)
        state.lastError = message
    }

    func clearTranscriptionFailure(for key: String) {
        guard let failure = lastTranscriptionFailure, failure.key == key else { return }
        lastTranscriptionFailure = nil
        if state.lastError == failure.message {
            state.lastError = nil
        }
    }

    nonisolated static func failureDescription(
        _ error: Error,
        session: RecordingSession,
        endedAt: Date? = nil
    ) -> String {
        do {
            try RecordingManifestStore.update(at: session.manifestURL) { manifest in
                if let endedAt { manifest.endedAt = endedAt }
                manifest.lifecycle = .failed
            }
            return error.localizedDescription
        } catch let persistenceError {
            return error.localizedDescription
                + " Recovery state could not be saved: "
                + persistenceError.localizedDescription
        }
    }

    private func finishTranscription(
        result: RecordingTranscriptionResult,
        key: String,
        destinationConfiguration: DestinationConfiguration
    ) {
        let finalNote = result.finalSession.noteURL
        if let processingWarning = result.processingWarning {
            notifier.notify(
                title: "Transcript agent skipped",
                body: processingWarning,
                category: "INFO",
                userInfo: ["notePath": finalNote.path])
            state.lastError = processingWarning
        } else {
            clearTranscriptionFailure(for: key)
        }
        notifier.notify(
            title: "Transcript ready",
            body: "Your transcript is ready.",
            category: "INFO",
            userInfo: ["notePath": finalNote.path])
        if let processorID = result.processorID,
           result.processingWarning == nil
        {
            notifier.notify(
                title: "Transcript processed",
                body: "Completed with \(processorID).",
                category: "INFO",
                userInfo: ["notePath": finalNote.path])
        }
        if destinationConfiguration.hasEnabledDestination {
            publish(
                session: result.finalSession,
                configuration: destinationConfiguration)
        }
        finishTranscriptionWork(key: key)
    }

    private func finishTranscriptionFailure(
        _ description: String,
        session: RecordingSession,
        key: String
    ) {
        notifier.notify(
            title: "Transcription failed",
            body: "Audio is safe. Retry from Recent recordings.",
            category: "TRANSCRIBE_FAILED",
            userInfo: ["notePath": session.noteURL.path])
        recordTranscriptionFailure(description, for: key)
        finishTranscriptionWork(key: key)
    }

    private func finishTranscriptionWork(key: String) {
        activeTranscriptions.remove(key)
        state.transcribingCount = activeTranscriptions.count
        onRecordingsChanged?()
    }

    private func finishPublication(
        results: [PublicationResult],
        session: RecordingSession,
        key: String
    ) {
        let failures = results.compactMap { result in
            result.errorDescription.map { "\(result.destinationID): \($0)" }
        }
        if failures.isEmpty {
            if let failure = lastPublicationFailure, failure.key == key {
                lastPublicationFailure = nil
                if state.lastError == failure.message {
                    state.lastError = nil
                }
            }
            notifier.notify(
                title: "Recording published",
                body: "Configured destinations are up to date.",
                category: "INFO",
                userInfo: ["notePath": session.noteURL.path])
        } else {
            let warning = "Publishing failed: \(failures.joined(separator: "; "))"
            notifier.notify(
                title: "Publishing failed",
                body: "The local recording is safe. Retry from Recent recordings.",
                category: "INFO",
                userInfo: ["notePath": session.noteURL.path])
            state.lastError = warning
            lastPublicationFailure = (key, warning)
        }
        activePublications.remove(key)
        state.publishingCount = activePublications.count
        onRecordingsChanged?()
    }
}
