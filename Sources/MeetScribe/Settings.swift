import Foundation

struct Settings: @unchecked Sendable {
    private let d: UserDefaults
    init(defaults: UserDefaults = .standard) { self.d = defaults }

    var outputFolder: URL {
        get { d.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) }
              ?? URL(fileURLWithPath: NSHomeDirectory() + "/Projects/BRAIN/04-meetings") }
        set { d.set(newValue.path, forKey: "outputFolder") }
    }
    var whisperModel: String {
        get { d.string(forKey: "whisperModel") ?? "mlx-community/whisper-large-v3-turbo" }
        set { d.set(newValue, forKey: "whisperModel") }
    }
    var mlxWhisperPath: String {
        get { d.string(forKey: "mlxWhisperPath")
              ?? NSHomeDirectory() + "/.local/share/mise/installs/python/3.12/bin/mlx_whisper" }
        set { d.set(newValue, forKey: "mlxWhisperPath") }
    }
    var claudeCleanupEnabled: Bool {
        get { d.object(forKey: "claudeCleanupEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "claudeCleanupEnabled") }
    }
    var hotKeyEnabled: Bool {
        get { d.object(forKey: "hotKeyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "hotKeyEnabled") }
    }
}
