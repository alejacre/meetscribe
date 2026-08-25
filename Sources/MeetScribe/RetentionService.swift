import Foundation

enum RetentionService {
    static func applyPostTranscription(
        session: RecordingSession,
        configuration: RetentionConfiguration
    ) throws {
        guard configuration.deleteSourceTracksAfterTranscription else { return }
        try removeExisting([session.micURL, session.systemURL])
    }

    static func applyAgePolicies(
        recordings: [RecordingRecord],
        configuration: RetentionConfiguration,
        now: Date = Date()
    ) throws {
        for recording in recordings {
            guard recording.manifest?.lifecycle == .ready else { continue }
            let session = RecordingSession(existingNote: recording.noteURL)
            let completedAt = recording.manifest?.transcript?.completedAt
                ?? recording.modifiedAt
            if expired(
                completedAt: completedAt,
                afterDays: configuration.audioRetentionDays,
                now: now)
            {
                try removeExisting([
                    session.mixURL,
                    session.micURL,
                    session.systemURL,
                ])
            }
            if expired(
                completedAt: completedAt,
                afterDays: configuration.rawTranscriptRetentionDays,
                now: now)
            {
                try removeExisting([session.transcriptJSON])
            }
        }
    }

    private static func expired(
        completedAt: Date,
        afterDays: Int?,
        now: Date
    ) -> Bool {
        guard let afterDays, afterDays > 0 else { return false }
        return now.timeIntervalSince(completedAt)
            >= TimeInterval(afterDays) * 24 * 60 * 60
    }

    private static func removeExisting(_ urls: [URL]) throws {
        let fileManager = FileManager.default
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
