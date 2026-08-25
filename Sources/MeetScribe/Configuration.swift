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
    var includeAudio = false
}

struct SFTPDestinationConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var host = ""
    var remotePath = ""
    var includeAudio = false
}

struct DestinationConfiguration: Codable, Equatable, Sendable {
    var git = GitDestinationConfiguration()
    var sftp = SFTPDestinationConfiguration()

    var hasEnabledDestination: Bool { git.enabled || sftp.enabled }
}

enum RecordingTriggerKind: String, Codable, Sendable {
    case manual
    case hotKey
    case meetingPrompt
    case meetingAutomatic
}
