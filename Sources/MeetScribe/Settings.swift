import Foundation

struct Settings: @unchecked Sendable {
    private let d: UserDefaults
    init(defaults: UserDefaults = .standard) { self.d = defaults }

    private enum Key {
        static let outputFolder = "outputFolder"
        static let whisperModel = "whisperModel"
        static let mlxWhisperPath = "mlxWhisperPath"
        static let claudeCleanupEnabled = "claudeCleanupEnabled"
        static let agentConfiguration = "agentConfiguration.v1"
        static let meetingRules = "meetingRules.v1"
        static let destinations = "destinationConfiguration.v1"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let setupCompleted = "setupCompleted"
        static let screenPermissionRequested = "screenPermissionRequested"
    }

    var outputFolder: URL {
        get { d.string(forKey: Key.outputFolder).map { URL(fileURLWithPath: $0) }
              ?? URL(fileURLWithPath: NSHomeDirectory() + "/Recordings") }
        set { d.set(newValue.path, forKey: Key.outputFolder) }
    }
    var whisperModel: String {
        get { d.string(forKey: Key.whisperModel) ?? "mlx-community/whisper-large-v3-turbo" }
        set { d.set(newValue, forKey: Key.whisperModel) }
    }
    var mlxWhisperPath: String {
        // Default matches `uv tool install mlx-whisper` (the setup wizard's installer);
        // the wizard overwrites this with the resolved path once it locates the binary.
        get { d.string(forKey: Key.mlxWhisperPath)
              ?? NSHomeDirectory() + "/.local/bin/mlx_whisper" }
        set { d.set(newValue, forKey: Key.mlxWhisperPath) }
    }

    var agentConfiguration: AgentConfiguration {
        get {
            if let stored: AgentConfiguration = decode(Key.agentConfiguration) {
                return stored
            }
            return d.object(forKey: Key.claudeCleanupEnabled) as? Bool == true
                ? .claudeCode
                : .disabled
        }
        set {
            encode(newValue, forKey: Key.agentConfiguration)
            d.set(newValue.provider == .claudeCode, forKey: Key.claudeCleanupEnabled)
        }
    }

    var claudeCleanupEnabled: Bool {
        get { agentConfiguration.provider == .claudeCode }
        set { agentConfiguration = newValue ? .claudeCode : .disabled }
    }

    var meetingRules: [MeetingRule] {
        get {
            MeetingApps.merged(with: decode(Key.meetingRules) ?? [])
        }
        set {
            encode(newValue, forKey: Key.meetingRules)
        }
    }

    var destinationConfiguration: DestinationConfiguration {
        get { decode(Key.destinations) ?? DestinationConfiguration() }
        set { encode(newValue, forKey: Key.destinations) }
    }

    var hotKeyEnabled: Bool {
        get { d.object(forKey: Key.hotKeyEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.hotKeyEnabled) }
    }
    var setupCompleted: Bool {
        get { d.object(forKey: Key.setupCompleted) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.setupCompleted) }
    }
    var screenPermissionRequested: Bool {
        get { d.object(forKey: Key.screenPermissionRequested) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.screenPermissionRequested) }
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        d.set(data, forKey: key)
    }
}
