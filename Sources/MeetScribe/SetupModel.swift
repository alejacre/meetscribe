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
        try? FileManager.default.createDirectory(
            at: s.outputFolder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
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
        Task { await checkEngine() }
        Task { await checkClaude() }
    }

    func cancelWork() { workTask?.cancel(); workTask = nil }

    func finish() {
        settings.setupCompleted = requiredSetupComplete
    }

    func onEnter(_ s: SetupStep) {
        switch s {
        case .engine: Task { await checkEngine() }
        case .model: checkModel()
        case .permissions: Task { await refreshPermissions() }
        case .cleanup: Task { await checkClaude() }
        default: break
        }
    }

    // MARK: Engine

    func checkEngine() async {
        enginePhase = .checking
        let result = await Task.detached(priority: .utility) {
            let path = ToolFinder.findTool("mlx_whisper")
            let uv = ToolFinder.findTool("uv")
            let list = uv.flatMap { try? Subprocess.run($0, ["tool", "list"], timeout: 30) }
            return (path, list)
        }.value
        if let path = result.0, Self.isPinnedEngineList(result.1 ?? "") {
            resolvedEnginePath = path
            settings.mlxWhisperPath = path
            enginePhase = .done
        } else {
            enginePhase = .missing
        }
    }

    /// Installs the locked mlx-whisper version through an existing trusted uv binary.
    func installEngine() {
        cancelWork()
        engineLog = ""; engineProgress = nil; enginePhase = .working
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let uv = await Task.detached(priority: .utility) {
                    ToolFinder.findTool("uv")
                }.value
                if uv == nil {
                    self.enginePhase = .failed(
                        "uv is required. Install it with Homebrew or the verified package from astral.sh.")
                    return
                }
                guard let uvPath = uv, FileManager.default.isExecutableFile(atPath: uvPath) else {
                    self.enginePhase = .failed("Could not install uv."); return
                }
                try await self.runLogged(
                    uvPath,
                    ["tool", "install", "--force",
                     "mlx-whisper==\(WhisperModels.mlxWhisperVersion)"],
                    into: \.engineLog)
                if Task.isCancelled { return }
                await self.checkEngine()
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
                guard let lockedModel = WhisperModels.model(id: model) else {
                    self.modelPhase = .failed("Select a supported model.")
                    return
                }
                try await WhisperModels.verifyPublishedRevision(for: lockedModel)
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
        WhisperModels.isCached(repo, cacheRoot: cacheRoot)
    }

    nonisolated static func isPinnedEngineList(_ output: String) -> Bool {
        output.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces)
                == "mlx-whisper v\(WhisperModels.mlxWhisperVersion)"
        }
    }

    // MARK: Permissions

    func refreshPermissions() async {
        screenPerm = Permissions.screenRecordingGranted ? .granted
            : settings.screenPermissionRequested ? .denied : .unknown
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

    func requestScreen() {
        settings.screenPermissionRequested = true
        Permissions.requestScreenRecording()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshPermissions()
        }
    }
    func requestMic() { Task { _ = await Permissions.requestMic(); await refreshPermissions() } }
    func requestNotifications() { Task { _ = await Permissions.requestNotifications(); await refreshPermissions() } }

    // MARK: Output + cleanup

    func setOutput(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        outputPath = url.path
        settings.outputFolder = url
    }

    func checkClaude() async {
        claudeFound = await Task.detached(priority: .utility) {
            ToolFinder.findTool("claude") != nil
        }.value
    }

    func setClaudeEnabled(_ on: Bool) {
        claudeEnabled = on
        settings.claudeCleanupEnabled = on
    }

    var requiredSetupComplete: Bool {
        guard case .done = enginePhase, case .done = modelPhase else { return false }
        return screenPerm == .granted
            && micPerm == .granted
            && FileManager.default.isWritableFile(atPath: outputPath)
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
