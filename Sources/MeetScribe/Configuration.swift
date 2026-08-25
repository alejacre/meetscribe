import Foundation

enum RecordingStartPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case ignore
    case ask
    case automatic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ignore: "Ignore"
        case .ask: "Ask before recording"
        case .automatic: "Record automatically"
        }
    }
}

struct MeetingRule: Codable, Equatable, Identifiable, Sendable {
    var bundleID: String
    var displayName: String
    var appName: String
    var policy: RecordingStartPolicy

    var id: String { bundleID }
}

enum MeetingApps {
    static let defaults: [MeetingRule] = [
        MeetingRule(bundleID: "us.zoom.xos", displayName: "Zoom", appName: "zoom", policy: .ask),
        MeetingRule(
            bundleID: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            appName: "slack",
            policy: .ask),
        MeetingRule(
            bundleID: "com.amazon.Amazon-Chime",
            displayName: "Amazon Chime",
            appName: "chime",
            policy: .ask),
        MeetingRule(
            bundleID: "com.microsoft.teams2",
            displayName: "Microsoft Teams",
            appName: "teams",
            policy: .ask),
        MeetingRule(
            bundleID: "com.microsoft.teams",
            displayName: "Microsoft Teams (classic)",
            appName: "teams",
            policy: .ask),
        MeetingRule(
            bundleID: "com.apple.FaceTime",
            displayName: "FaceTime",
            appName: "facetime",
            policy: .ask),
        MeetingRule(
            bundleID: "com.cisco.webexmeetingsapp",
            displayName: "Webex Meetings",
            appName: "webex",
            policy: .ask),
        MeetingRule(
            bundleID: "Cisco-Systems.Spark",
            displayName: "Webex",
            appName: "webex",
            policy: .ask),
    ]

    static func merged(with configured: [MeetingRule]) -> [MeetingRule] {
        var byBundleID = Dictionary(uniqueKeysWithValues: defaults.map { ($0.bundleID, $0) })
        for rule in configured {
            byBundleID[rule.bundleID] = rule
        }
        return byBundleID.values.sorted {
            if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
            return $0.bundleID < $1.bundleID
        }
    }
}

enum AgentProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case claudeCode
    case kiroCLI
    case customCommand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled: "None"
        case .claudeCode: "Claude Code"
        case .kiroCLI: "Kiro CLI"
        case .customCommand: "Custom command"
        }
    }
}

struct AgentConfiguration: Codable, Equatable, Sendable {
    var provider: AgentProviderKind = .disabled
    var customExecutable = ""
    var customArguments: [String] = []
    var customPrompt = TranscriptProcessorSupport.defaultPrompt
    var inheritEnvironment = false

    static let disabled = AgentConfiguration()
    static let claudeCode = AgentConfiguration(provider: .claudeCode)
    static let kiroCLI = AgentConfiguration(provider: .kiroCLI)
}

struct GitDestinationConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var repositoryPath = ""
    var relativePath = "meetings"
    var includeManifest = false
    var includeRawTranscript = false
    var includeAudio = false

    private enum CodingKeys: String, CodingKey {
        case enabled, repositoryPath, relativePath
        case includeManifest, includeRawTranscript, includeAudio
    }

    init(
        enabled: Bool = false,
        repositoryPath: String = "",
        relativePath: String = "meetings",
        includeManifest: Bool = false,
        includeRawTranscript: Bool = false,
        includeAudio: Bool = false
    ) {
        self.enabled = enabled
        self.repositoryPath = repositoryPath
        self.relativePath = relativePath
        self.includeManifest = includeManifest
        self.includeRawTranscript = includeRawTranscript
        self.includeAudio = includeAudio
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        repositoryPath = try values.decodeIfPresent(String.self, forKey: .repositoryPath) ?? ""
        relativePath = try values.decodeIfPresent(String.self, forKey: .relativePath) ?? "meetings"
        includeManifest = try values.decodeIfPresent(Bool.self, forKey: .includeManifest) ?? false
        includeRawTranscript = try values.decodeIfPresent(Bool.self, forKey: .includeRawTranscript) ?? false
        includeAudio = try values.decodeIfPresent(Bool.self, forKey: .includeAudio) ?? false
    }
}

struct SFTPDestinationConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var host = ""
    var remotePath = ""
    var includeManifest = false
    var includeRawTranscript = false
    var includeAudio = false

    private enum CodingKeys: String, CodingKey {
        case enabled, host, remotePath
        case includeManifest, includeRawTranscript, includeAudio
    }

    init(
        enabled: Bool = false,
        host: String = "",
        remotePath: String = "",
        includeManifest: Bool = false,
        includeRawTranscript: Bool = false,
        includeAudio: Bool = false
    ) {
        self.enabled = enabled
        self.host = host
        self.remotePath = remotePath
        self.includeManifest = includeManifest
        self.includeRawTranscript = includeRawTranscript
        self.includeAudio = includeAudio
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        remotePath = try values.decodeIfPresent(String.self, forKey: .remotePath) ?? ""
        includeManifest = try values.decodeIfPresent(Bool.self, forKey: .includeManifest) ?? false
        includeRawTranscript = try values.decodeIfPresent(Bool.self, forKey: .includeRawTranscript) ?? false
        includeAudio = try values.decodeIfPresent(Bool.self, forKey: .includeAudio) ?? false
    }
}

struct DestinationConfiguration: Codable, Equatable, Sendable {
    var git = GitDestinationConfiguration()
    var sftp = SFTPDestinationConfiguration()

    var hasEnabledDestination: Bool { git.enabled || sftp.enabled }
}

struct RetentionConfiguration: Codable, Equatable, Sendable {
    var deleteSourceTracksAfterTranscription = false
    var audioRetentionDays: Int?
    var rawTranscriptRetentionDays: Int?
}

enum RecordingTriggerKind: String, Codable, Sendable {
    case manual
    case hotKey
    case meetingPrompt
    case meetingAutomatic
}
