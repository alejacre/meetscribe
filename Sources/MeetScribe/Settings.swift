import Foundation

struct Settings: @unchecked Sendable {
    private let d: UserDefaults
    init(defaults: UserDefaults = .standard) { self.d = defaults }

    var outputFolder: URL {
        get { d.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) }
              ?? URL(fileURLWithPath: NSHomeDirectory() + "/Recordings") }
        set { d.set(newValue.path, forKey: "outputFolder") }
    }
    var whisperModel: String {
        get { d.string(forKey: "whisperModel") ?? "mlx-community/whisper-large-v3-turbo" }
        set { d.set(newValue, forKey: "whisperModel") }
    }
    var mlxWhisperPath: String {
        // Default matches `uv tool install mlx-whisper` (the setup wizard's installer);
        // the wizard overwrites this with the resolved path once it locates the binary.
        get { d.string(forKey: "mlxWhisperPath")
              ?? NSHomeDirectory() + "/.local/bin/mlx_whisper" }
        set { d.set(newValue, forKey: "mlxWhisperPath") }
    }
    var claudeCleanupEnabled: Bool {
        get { d.object(forKey: "claudeCleanupEnabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "claudeCleanupEnabled") }
    }
    var hotKeyEnabled: Bool {
        get { d.object(forKey: "hotKeyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "hotKeyEnabled") }
    }
    var setupCompleted: Bool {
        get { d.object(forKey: "setupCompleted") as? Bool ?? false }
        set { d.set(newValue, forKey: "setupCompleted") }
    }
    var screenPermissionRequested: Bool {
        get { d.object(forKey: "screenPermissionRequested") as? Bool ?? false }
        set { d.set(newValue, forKey: "screenPermissionRequested") }
    }
}
