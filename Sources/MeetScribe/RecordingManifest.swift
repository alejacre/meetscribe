import Foundation

enum RecordingLifecycle: String, Codable, Sendable {
    case recording
    case recorded
    case transcribing
    case ready
    case failed
}

enum DestinationPublicationPhase: String, Codable, Sendable {
    case pending
    case publishing
    case succeeded
    case failed
}

struct RecordingSourceMetadata: Codable, Equatable, Sendable {
    var appName: String?
    var bundleID: String?
    var trigger: RecordingTriggerKind
}

struct TranscriptRunMetadata: Codable, Equatable, Sendable {
    var completedAt: Date
    var model: String
    var processorID: String?
}

struct DestinationPublication: Codable, Equatable, Identifiable, Sendable {
    var destinationID: String
    var configurationFingerprint: String
    var phase: DestinationPublicationPhase
    var attempts: Int
    var lastError: String?
    var publishedAt: Date?

    var id: String { destinationID }
}

struct RecordingManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var source: RecordingSourceMetadata
    var lifecycle: RecordingLifecycle
    var transcript: TranscriptRunMetadata?
    var publicationRequestedAt: Date?
    var destinations: [DestinationPublication]

    static func initial(
        id: UUID,
        startedAt: Date,
        appName: String?,
        bundleID: String?,
        trigger: RecordingTriggerKind
    ) -> RecordingManifest {
        RecordingManifest(
            id: id,
            startedAt: startedAt,
            source: RecordingSourceMetadata(
                appName: appName,
                bundleID: bundleID,
                trigger: trigger),
            lifecycle: .recording,
            destinations: [])
    }
}

enum RecordingManifestError: Error, LocalizedError {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Recording manifest schema \(version) is not supported by this version of MeetScribe."
        }
    }
}

enum RecordingManifestStore {
    private static let lock = NSLock()

    static func load(from url: URL) throws -> RecordingManifest {
        let manifest = try decoder.decode(RecordingManifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == RecordingManifest.currentSchemaVersion else {
            throw RecordingManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        return manifest
    }

    static func loadIfPresent(from url: URL) -> RecordingManifest? {
        try? load(from: url)
    }

    static func write(_ manifest: RecordingManifest, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeUnlocked(manifest, to: url)
    }

    static func update(at url: URL, _ update: (inout RecordingManifest) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var manifest = try load(from: url)
        update(&manifest)
        try writeUnlocked(manifest, to: url)
    }

    private static func writeUnlocked(_ manifest: RecordingManifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
