import Foundation
import AVFoundation
import UserNotifications

enum SetupStep: Int, CaseIterable {
    case welcome, engine, model, permissions, output, cleanup, done
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .engine: "Transcription engine"
        case .model: "Whisper model"
        case .permissions: "Permissions"
        case .output: "Where to save"
        case .cleanup: "Claude cleanup"
        case .done: "All set"
        }
    }
}

/// State of a check-then-install/download style step.
enum StepPhase: Equatable {
    case checking          // probing the system
    case missing           // needs an install/download action
    case working           // install/download in progress
    case done              // satisfied
    case failed(String)    // last attempt failed, with message
}

enum PermState: Equatable { case unknown, granted, denied }

@MainActor
final class SetupModel: ObservableObject {
    @Published var step: SetupStep = .welcome

    // Engine
    @Published var enginePhase: StepPhase = .checking
    @Published var engineLog = ""
    @Published var engineProgress: Int?      // parsed %, nil = indeterminate
    var resolvedEnginePath: String?

    // Model
    @Published var modelPhase: StepPhase = .checking
    @Published var modelLog = ""
    @Published var modelProgress: Int?
    @Published var selectedModel: String

    // Permissions
    @Published var screenPerm: PermState = .unknown
    @Published var micPerm: PermState = .unknown
    @Published var notifPerm: PermState = .unknown

    // Output + cleanup
    @Published var outputPath: String
    @Published var claudeFound: Bool?        // nil = not yet checked
    @Published var claudeEnabled: Bool

    private var settings = Settings()
    private var workTask: Task<Void, Never>?

    init() {
        let s = Settings()
        outputPath = s.outputFolder.path
        claudeEnabled = s.claudeCleanupEnabled
        selectedModel = s.whisperModel
    }

    func selectModel(_ m: String) {
        selectedModel = m
        settings.whisperModel = m
        checkModel()
    }

    // MARK: Lifecycle

    /// Kicks off the cheap checks that don't need user action.
    func beginChecks() {
        checkEngine()
        checkClaude()
    }

    func cancelWork() { workTask?.cancel(); workTask = nil }

    func finish() {
        settings.setupCompleted = true
    }

    func onEnter(_ s: SetupStep) {
        switch s {
        case .engine: checkEngine()
        case .model: checkModel()
        case .permissions: Task { await refreshPermissions() }
        case .cleanup: checkClaude()
        default: break
        }
    }

    // MARK: Engine

    func checkEngine() {
        enginePhase = .checking
        if let path = ToolFinder.findTool("mlx_whisper") {
            resolvedEnginePath = path
            settings.mlxWhisperPath = path
            enginePhase = .done
        } else {
            enginePhase = .missing
        }
    }

    /// Installs mlx-whisper via uv, bootstrapping uv itself if absent. Streams the
    /// combined installer output into `engineLog` for a live view.
    func installEngine() {
        cancelWork()
        engineLog = ""; engineProgress = nil; enginePhase = .working
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                var uv = ToolFinder.findTool("uv")
                if uv == nil {
                    try await self.runLogged(
                        "/bin/zsh", ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
                        into: \.engineLog)
                    uv = ToolFinder.findTool("uv") ?? NSHomeDirectory() + "/.local/bin/uv"
                }
                guard let uvPath = uv, FileManager.default.isExecutableFile(atPath: uvPath) else {
                    self.enginePhase = .failed("Could not install uv."); return
                }
                try await self.runLogged(uvPath, ["tool", "install", "mlx-whisper"], into: \.engineLog)
                if Task.isCancelled { return }
                self.checkEngine()
                if case .done = self.enginePhase {} else {
                    self.enginePhase = .failed("mlx_whisper not found after install.")
                }
            } catch is CancellationError {
                self.enginePhase = .missing
            } catch {
                self.enginePhase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Model

    func checkModel() {
        modelPhase = Self.modelCached(selectedModel) ? .done : .missing
    }

    /// Warms the HuggingFace cache by transcribing a silent clip. mlx_whisper/HF print
    /// tqdm progress to stderr, streamed into `modelLog`.
    func downloadModel() {
        cancelWork()
        modelLog = ""; modelProgress = nil; modelPhase = .working
        let model = selectedModel
        let bin = settings.mlxWhisperPath
        workTask = Task { [weak self] in
            guard let self else { return }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("meetscribe-warm-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let wav = tmp.appendingPathComponent("silent.wav")
                try SilentWav.write(to: wav)
                try await self.runLogged(bin, [
                    wav.path, "--model", model, "--output-format", "json",
                    "--output-dir", tmp.path, "--output-name", "silent",
                ], into: \.modelLog, progress: \.modelProgress)
                if Task.isCancelled { return }
                self.modelPhase = Self.modelCached(model) ? .done
                    : .failed("Download finished but model is not cached.")
            } catch is CancellationError {
                self.modelPhase = .missing
            } catch {
                self.modelPhase = .failed(error.localizedDescription)
            }
        }
    }

    /// Maps a HF repo id to its cache dir and checks existence.
    /// `mlx-community/whisper-large-v3-turbo` → `~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo`.
    nonisolated static func modelCached(_ repo: String, cacheRoot: URL? = nil) -> Bool {
        let root = cacheRoot ?? URL(fileURLWithPath: NSHomeDirectory() + "/.cache/huggingface/hub")
        let dir = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(dir).path)
    }

    // MARK: Permissions

    func refreshPermissions() async {
        screenPerm = Permissions.screenRecordingGranted ? .granted : .denied
        switch Permissions.micStatus {
        case .authorized: micPerm = .granted
        case .notDetermined: micPerm = .unknown
        default: micPerm = .denied
        }
        switch await Permissions.notificationStatus() {
        case .authorized, .provisional, .ephemeral: notifPerm = .granted
        case .notDetermined: notifPerm = .unknown
        default: notifPerm = .denied
        }
    }

    func requestScreen() { Permissions.requestScreenRecording(); Task { await refreshPermissions() } }
    func requestMic() { Task { _ = await Permissions.requestMic(); await refreshPermissions() } }
    func requestNotifications() { Task { _ = await Permissions.requestNotifications(); await refreshPermissions() } }

    // MARK: Output + cleanup

    func setOutput(_ url: URL) {
        outputPath = url.path
        settings.outputFolder = url
    }

    func checkClaude() { claudeFound = ClaudeCleaner.resolvedBinary != nil }

    func setClaudeEnabled(_ on: Bool) {
        claudeEnabled = on
        settings.claudeCleanupEnabled = on
    }

    // MARK: Streaming helper

    /// Streams a subprocess, appending each chunk to the given log keypath (with tqdm
    /// carriage-return handling) and optionally parsing a percentage into a keypath.
    private func runLogged(_ bin: String, _ args: [String],
                           into log: ReferenceWritableKeyPath<SetupModel, String>,
                           progress: ReferenceWritableKeyPath<SetupModel, Int?>? = nil) async throws {
        for try await chunk in Subprocess.stream(bin, args) {
            if Task.isCancelled { throw CancellationError() }
            self[keyPath: log] = Self.appendLog(self[keyPath: log], chunk: chunk)
            if let progress, let pct = Self.progressPercent(in: chunk) {
                self[keyPath: progress] = pct
            }
        }
    }

    // MARK: Pure text helpers (unit-tested)

    /// Appends a chunk to a log, emulating a terminal's handling of `\r`: a carriage
    /// return rewrites the current line (how tqdm animates its bar in place).
    nonisolated static func appendLog(_ log: String, chunk: String) -> String {
        var result = log
        for scalar in chunk {
            if scalar == "\r" {
                // Drop back to the start of the current line.
                if let nl = result.lastIndex(of: "\n") {
                    result = String(result[...nl])
                } else {
                    result = ""
                }
            } else {
                result.append(scalar)
            }
        }
        return result
    }

    /// Extracts the last `NN%` token from a chunk (tqdm-style), 0...100.
    nonisolated static func progressPercent(in chunk: String) -> Int? {
        var last: Int?
        var digits = ""
        for ch in chunk {
            if ch.isNumber {
                digits.append(ch)
                if digits.count > 3 { digits.removeFirst(digits.count - 3) }
            } else if ch == "%" {
                if let n = Int(digits), (0...100).contains(n) { last = n }
                digits = ""
            } else {
                digits = ""
            }
        }
        return last
    }
}
