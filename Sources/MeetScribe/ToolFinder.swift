import Foundation

/// Locates a CLI binary by name: fixed candidate dirs first (fast, no shell), then
/// the user's shell PATH (covers version-managed installs like uv/mise/asdf/nvm
/// whose paths change across upgrades). The shell probe is expensive since it sources
/// the profile, so callers should cache results per app run.
enum ToolFinder {
    static let candidateDirs = [
        NSHomeDirectory() + "/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        // Version managers expose binaries through a shims dir on PATH, not a
        // fixed bin dir. mise/asdf are the common ones; include them explicitly so
        // detection doesn't depend on the shell probe below succeeding.
        NSHomeDirectory() + "/.local/share/mise/shims",
        NSHomeDirectory() + "/.asdf/shims",
    ]

    static func findTool(_ name: String) -> String? {
        for dir in candidateDirs {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // `-ilc` = interactive login: sources .zshrc (where mise/asdf/nvm hook their
        // `activate`), which a plain `-lc` shell skips  -  that miss is exactly why a
        // mise-managed tool looked absent. `command -v` resolves shims and functions.
        guard let path = try? Subprocess.run("/bin/zsh", ["-ilc", "command -v \(name)"], timeout: 30)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty, FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }
}
