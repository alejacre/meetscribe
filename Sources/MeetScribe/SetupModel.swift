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
        case .cleanup: "Transcript agent"
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

struct SetupModelDependencies: Sendable {
    let findTool: @Sendable (String) -> String?
    let isExecutable: @Sendable (String) -> Bool
    let verifyPublishedRevision: @Sendable (WhisperModel) async throws -> Void
    let modelCached: @Sendable (String) -> Bool
    let screenRecordingGranted: @Sendable () -> Bool
    let micStatus: @Sendable () -> AVAuthorizationStatus
    let notificationStatus: @Sendable () async -> UNAuthorizationStatus
    let requestScreenRecording: @Sendable () -> Bool
    let requestMic: @Sendable () async -> Bool
    let requestNotifications: @Sendable () async -> Bool
    let permissionRefreshDelay: @Sendable () async -> Void
    let managedToolRoot: URL
    let managedBinRoot: URL

    static let live = SetupModelDependencies(
        findTool: ToolFinder.findTool,
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
        verifyPublishedRevision: WhisperModels.verifyPublishedRevision,
        modelCached: { WhisperModels.isCached($0) },
        screenRecordingGranted: { Permissions.screenRecordingGranted },
        micStatus: { Permissions.micStatus },
        notificationStatus: { await Permissions.notificationStatus() },
        requestScreenRecording: Permissions.requestScreenRecording,
        requestMic: Permissions.requestMic,
        requestNotifications: Permissions.requestNotifications,
        permissionRefreshDelay: { try? await Task.sleep(for: .milliseconds(500)) },
        managedToolRoot: SetupModel.managedToolRoot,
        managedBinRoot: SetupModel.managedBinRoot)
}

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
    @Published var kiroFound: Bool?          // nil = not yet checked
    @Published var agentProvider: AgentProviderKind

    private var settings: Settings
    private let dependencies: SetupModelDependencies
    private var workTask: Task<Void, Never>?

    nonisolated static var managedToolRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MeetScribe/uv-tools", isDirectory: true)
    }

    nonisolated static var managedBinRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MeetScribe/bin", isDirectory: true)
    }

    nonisolated static var engineConstraintsURL: URL? {
        if let bundled = Bundle.main.url(
            forResource: "mlx-whisper-constraints",
            withExtension: "txt")
        {
            return bundled
        }
        let sourceTree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/mlx-whisper-constraints.txt")
        return FileManager.default.fileExists(atPath: sourceTree.path)
            ? sourceTree
            : nil
    }

    init(
        settings: Settings = Settings(),
        dependencies: SetupModelDependencies = .live
    ) {
        self.settings = settings
        self.dependencies = dependencies
        outputPath = settings.outputFolder.path
        try? FileManager.default.createDirectory(
            at: settings.outputFolder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        agentProvider = settings.agentConfiguration.provider
        selectedModel = settings.whisperModel
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
        Task { await checkAgents() }
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
        case .cleanup: Task { await checkAgents() }
        default: break
        }
    }

    // MARK: Engine

    func checkEngine() async {
        enginePhase = .checking
        let configuredPath = (settings.mlxWhisperPath as NSString).expandingTildeInPath
        let dependencies = dependencies
        let result = await Task.detached(priority: .utility) { () -> String? in
            let uv = dependencies.findTool("uv")
            if dependencies.isExecutable(configuredPath) {
                return configuredPath
            }
            let managedPath = dependencies.managedBinRoot
                .appendingPathComponent("mlx_whisper").path
            if dependencies.isExecutable(managedPath) {
                return managedPath
            }
            guard let path = dependencies.findTool("mlx_whisper") else { return nil }
            guard let uv else { return path }
            let list = try? Subprocess.run(uv, ["tool", "list"], timeout: 30)
            return Self.isPinnedEngineList(list ?? "") ? path : nil
        }.value
        if let path = result {
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
                let dependencies = self.dependencies
                let uv = await Task.detached(priority: .utility) {
                    dependencies.findTool("uv")
                }.value
                if uv == nil {
                    self.enginePhase = .failed(
                        "uv is required. Install it with Homebrew or the verified package from astral.sh.")
                    return
                }
                guard let uvPath = uv, dependencies.isExecutable(uvPath) else {
                    self.enginePhase = .failed("Could not install uv."); return
                }
                guard let constraints = Self.engineConstraintsURL else {
                    self.enginePhase = .failed(
                        "The locked mlx-whisper dependency constraints are missing.")
                    return
                }
                try FileManager.default.createDirectory(
                    at: dependencies.managedToolRoot,
                    withIntermediateDirectories: true)
                try FileManager.default.createDirectory(
                    at: dependencies.managedBinRoot,
                    withIntermediateDirectories: true)
                try await self.runLogged(
                    uvPath,
                    ["tool", "install", "--force",
                     "--constraints", constraints.path,
                     "mlx-whisper==\(WhisperModels.mlxWhisperVersion)"],
                    into: \.engineLog,
                    environment: self.managedToolEnvironment)
                if Task.isCancelled { return }
                self.settings.mlxWhisperPath = dependencies.managedBinRoot
                    .appendingPathComponent("mlx_whisper").path
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
        modelPhase = dependencies.modelCached(selectedModel) ? .done : .missing
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
                try await self.dependencies.verifyPublishedRevision(lockedModel)
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let wav = tmp.appendingPathComponent("silent.wav")
                try SilentWav.write(to: wav)
                try await self.runLogged(bin, [
                    wav.path, "--model", model, "--output-format", "json",
                    "--output-dir", tmp.path, "--output-name", "silent",
                ], into: \.modelLog, progress: \.modelProgress)
                if Task.isCancelled { return }
                self.modelPhase = self.dependencies.modelCached(model) ? .done
                    : .failed("Download finished but model is not cached.")
            } catch is CancellationError {
                self.modelPhase = .missing
            } catch {
                self.modelPhase = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func isPinnedEngineList(_ output: String) -> Bool {
        output.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces)
                == "mlx-whisper v\(WhisperModels.mlxWhisperVersion)"
        }
    }

    // MARK: Permissions

    func refreshPermissions() async {
        screenPerm = dependencies.screenRecordingGranted() ? .granted
            : settings.screenPermissionRequested ? .denied : .unknown
        switch dependencies.micStatus() {
        case .authorized: micPerm = .granted
        case .notDetermined: micPerm = .unknown
        default: micPerm = .denied
        }
        switch await dependencies.notificationStatus() {
        case .authorized, .provisional, .ephemeral: notifPerm = .granted
        case .notDetermined: notifPerm = .unknown
        default: notifPerm = .denied
        }
    }

    func requestScreen() {
        settings.screenPermissionRequested = true
        _ = dependencies.requestScreenRecording()
        Task {
            await dependencies.permissionRefreshDelay()
            await refreshPermissions()
        }
    }
    func requestMic() { Task { _ = await dependencies.requestMic(); await refreshPermissions() } }
    func requestNotifications() {
        Task { _ = await dependencies.requestNotifications(); await refreshPermissions() }
    }

    // MARK: Output + cleanup

    func setOutput(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        outputPath = url.path
        settings.outputFolder = url
    }

    func checkAgents() async {
        let dependencies = dependencies
        async let claude = Task.detached(priority: .utility) {
            dependencies.findTool("claude") != nil
        }.value
        async let kiro = Task.detached(priority: .utility) {
            dependencies.findTool("kiro-cli") != nil
        }.value
        claudeFound = await claude
        kiroFound = await kiro
    }

    func setAgentProvider(_ provider: AgentProviderKind) {
        agentProvider = provider
        var configuration = settings.agentConfiguration
        configuration.provider = provider
        settings.agentConfiguration = configuration
    }

    var requiredSetupComplete: Bool {
        guard case .done = enginePhase, case .done = modelPhase else { return false }
        return screenPerm == .granted
            && micPerm == .granted
            && FileManager.default.isWritableFile(atPath: outputPath)
    }

    private var managedToolEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["UV_TOOL_DIR"] = dependencies.managedToolRoot.path
        environment["UV_TOOL_BIN_DIR"] = dependencies.managedBinRoot.path
        return environment
    }

    // MARK: Streaming helper

    /// Streams a subprocess, appending each chunk to the given log keypath (with tqdm
    /// carriage-return handling) and optionally parsing a percentage into a keypath.
    private func runLogged(_ bin: String, _ args: [String],
                           into log: ReferenceWritableKeyPath<SetupModel, String>,
                           progress: ReferenceWritableKeyPath<SetupModel, Int?>? = nil,
                           environment: [String: String]? = nil) async throws {
        for try await chunk in Subprocess.stream(bin, args, environment: environment) {
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
