import Foundation

/// Locates a CLI binary by name: fixed candidate dirs first (fast, no shell), then
/// the user's login-shell PATH (covers version-managed installs like uv/mise/nvm
/// whose paths change across upgrades). The login-shell probe is expensive since it
/// sources the full zsh profile, so callers should cache results per app run.
enum ToolFinder {
    static let candidateDirs = [
        NSHomeDirectory() + "/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    static func findTool(_ name: String) -> String? {
        for dir in candidateDirs {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        guard let path = try? Subprocess.run("/bin/zsh", ["-lc", "which \(name)"], timeout: 30)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty, FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }
}
