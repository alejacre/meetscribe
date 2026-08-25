import AVFoundation
import UserNotifications
import XCTest
@testable import MeetScribe

@MainActor
final class SetupModelTests: XCTestCase {
    nonisolated(unsafe) private var roots: [URL] = []
    nonisolated(unsafe) private var suites: [String] = []

    override func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        roots = []
        suites = []
    }

    func testModelCachePathMapping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = "mlx-community/whisper-large-v3-turbo"
        XCTAssertFalse(WhisperModels.isCached(repo, cacheRoot: root))

        let model = try XCTUnwrap(WhisperModels.model(id: repo))
        let dir = WhisperModels.snapshotURL(for: model, cacheRoot: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: dir.appendingPathComponent("weights.safetensors"))
        XCTAssertTrue(WhisperModels.isCached(repo, cacheRoot: root))
    }

    func testProgressPercent() {
        XCTAssertEqual(SetupModel.progressPercent(in: " 47%|████     | 1.2G/2.5G"), 47)
        XCTAssertNil(SetupModel.progressPercent(in: "downloading shards"))
        XCTAssertEqual(SetupModel.progressPercent(in: "10% ... 55% ... 100%"), 100)
        XCTAssertNil(SetupModel.progressPercent(in: "512% garbage"))  // out of range ignored
    }

    func testPinnedEngineVersionParsing() {
        XCTAssertTrue(SetupModel.isPinnedEngineList("""
        other-tool v1.0
        mlx-whisper v0.4.3
        - mlx_whisper
        """))
        XCTAssertFalse(SetupModel.isPinnedEngineList("mlx-whisper v0.5.0"))
    }

    func testEngineDependencyConstraintsAreAvailable() throws {
        let constraints = try XCTUnwrap(SetupModel.engineConstraintsURL)
        XCTAssertFalse(try String(contentsOf: constraints, encoding: .utf8).isEmpty)
    }

    func testAppendLogCarriageReturnRewritesLastLine() {
        var log = ""
        log = SetupModel.appendLog(log, chunk: "line one\n")
        log = SetupModel.appendLog(log, chunk: "10%")
        log = SetupModel.appendLog(log, chunk: "\r50%")
        log = SetupModel.appendLog(log, chunk: "\r100%")
        XCTAssertEqual(log, "line one\n100%")
    }

    func testAppendLogCarriageReturnAtStartClearsWhenNoNewline() {
        let log = SetupModel.appendLog("abc", chunk: "\rxy")
        XCTAssertEqual(log, "xy")
    }

    func testStepTitles() {
        XCTAssertEqual(
            SetupStep.allCases.map(\.title),
            [
                "Welcome",
                "Transcription engine",
                "Whisper model",
                "Permissions",
                "Where to save",
                "Transcript agent",
                "All set",
            ])
    }

    func testSetupPreservesAndCanChangeCustomAgentProvider() throws {
        var settings = try makeSettings("custom-agent-provider")
        settings.agentConfiguration = AgentConfiguration(
            provider: .customCommand,
            customExecutable: "/tmp/transcript-agent",
            customArguments: ["--prompt", "{prompt}"],
            customPrompt: "Clean this transcript")
        let model = SetupModel(settings: settings)

        XCTAssertEqual(model.agentProvider, .customCommand)
        model.setAgentProvider(.kiroCLI)

        XCTAssertEqual(model.agentProvider, .kiroCLI)
        XCTAssertEqual(settings.agentConfiguration.provider, .kiroCLI)
        XCTAssertEqual(
            settings.agentConfiguration.customExecutable,
            "/tmp/transcript-agent")
    }

    func testCheckEngineAcceptsConfiguredAndPinnedDiscoveredTools() async throws {
        let harness = Harness(root: try temporaryDirectory("check-engine"))
        var settings = try makeSettings("check-engine")
        let configured = try makeExecutable("#!/bin/sh\nexit 0\n", in: harness.root, name: "configured")
        settings.mlxWhisperPath = configured.path
        let model = SetupModel(settings: settings, dependencies: harness.dependencies())

        await model.checkEngine()

        XCTAssertEqual(model.enginePhase, .done)
        XCTAssertEqual(model.resolvedEnginePath, configured.path)

        try FileManager.default.removeItem(at: configured)
        let discovered = try makeExecutable("#!/bin/sh\nexit 0\n", in: harness.root, name: "mlx_whisper")
        let uv = try makeExecutable(
            "#!/bin/sh\nprintf 'mlx-whisper v\(WhisperModels.mlxWhisperVersion)\\n'\n",
            in: harness.root,
            name: "uv")
        harness.tools = ["mlx_whisper": discovered.path, "uv": uv.path]
        await model.checkEngine()

        XCTAssertEqual(model.enginePhase, .done)
        XCTAssertEqual(model.resolvedEnginePath, discovered.path)
    }

    func testCheckEngineReportsMissingWhenNoTrustedToolExists() async throws {
        let harness = Harness(root: try temporaryDirectory("missing-engine"))
        var settings = try makeSettings("missing-engine")
        settings.mlxWhisperPath = harness.root.appendingPathComponent("missing").path
        let model = SetupModel(
            settings: settings,
            dependencies: harness.dependencies())

        await model.checkEngine()

        XCTAssertEqual(model.enginePhase, .missing)
    }

    func testInstallEngineReportsMissingUV() async throws {
        let harness = Harness(root: try temporaryDirectory("install-no-uv"))
        let model = SetupModel(
            settings: try makeSettings("install-no-uv"),
            dependencies: harness.dependencies())

        model.installEngine()
        await waitUntil { model.enginePhase != .working }

        XCTAssertEqual(
            model.enginePhase,
            .failed("uv is required. Install it with Homebrew or the verified package from astral.sh."))
    }

    func testInstallEngineStreamsLogAndPersistsManagedBinary() async throws {
        let harness = Harness(root: try temporaryDirectory("install-success"))
        let uv = try makeExecutable(
            """
            #!/bin/sh
            mkdir -p "$UV_TOOL_BIN_DIR"
            printf '#!/bin/sh\\nexit 0\\n' > "$UV_TOOL_BIN_DIR/mlx_whisper"
            chmod +x "$UV_TOOL_BIN_DIR/mlx_whisper"
            printf 'installed 100%%\\n'
            """,
            in: harness.root,
            name: "uv")
        harness.tools["uv"] = uv.path
        let settings = try makeSettings("install-success")
        let model = SetupModel(settings: settings, dependencies: harness.dependencies())

        model.installEngine()
        await waitUntil { model.enginePhase == .done }

        let expected = harness.managedBinRoot.appendingPathComponent("mlx_whisper").path
        XCTAssertEqual(model.enginePhase, .done)
        XCTAssertEqual(model.resolvedEnginePath, expected)
        XCTAssertTrue(model.engineLog.contains("installed 100%"))
        XCTAssertEqual(settings.mlxWhisperPath, expected)
    }

    func testModelSelectionAndDownloadSuccess() async throws {
        let harness = Harness(root: try temporaryDirectory("download-success"))
        let whisper = try makeExecutable(
            "#!/bin/sh\nprintf 'download 75%%\\n'\n",
            in: harness.root,
            name: "mlx_whisper")
        var settings = try makeSettings("download-success")
        settings.mlxWhisperPath = whisper.path
        let model = SetupModel(settings: settings, dependencies: harness.dependencies())
        let selected = try XCTUnwrap(WhisperModels.all.last?.id)
        model.selectModel(selected)
        XCTAssertEqual(model.modelPhase, .missing)
        harness.cachedModels.insert(selected)

        model.downloadModel()
        await waitUntil { model.modelPhase != .working }

        XCTAssertEqual(model.modelPhase, .done)
        XCTAssertEqual(model.modelProgress, 75)
        XCTAssertTrue(model.modelLog.contains("download 75%"))
        XCTAssertEqual(settings.whisperModel, selected)
    }

    func testDownloadModelRejectsUnsupportedModelAndRevisionFailure() async throws {
        let harness = Harness(root: try temporaryDirectory("download-failure"))
        let model = SetupModel(
            settings: try makeSettings("download-failure"),
            dependencies: harness.dependencies())
        model.selectedModel = "unsupported/model"

        model.downloadModel()
        await waitUntil { model.modelPhase != .working }
        XCTAssertEqual(model.modelPhase, .failed("Select a supported model."))

        model.selectedModel = try XCTUnwrap(WhisperModels.all.first?.id)
        harness.revisionError = TestError.expected
        model.downloadModel()
        await waitUntil { model.modelPhase != .working }
        guard case .failed(let message) = model.modelPhase else {
            return XCTFail("expected failed phase")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testPermissionsRequestsAndRefreshUseInjectedStatuses() async throws {
        let harness = Harness(root: try temporaryDirectory("permissions"))
        let settings = try makeSettings("permissions")
        let model = SetupModel(settings: settings, dependencies: harness.dependencies())

        await model.refreshPermissions()
        XCTAssertEqual(model.screenPerm, .unknown)
        XCTAssertEqual(model.micPerm, .unknown)
        XCTAssertEqual(model.notifPerm, .unknown)

        harness.grantOnRequest = true
        model.requestScreen()
        model.requestMic()
        model.requestNotifications()
        await waitUntil {
            harness.screenRequests == 1
                && harness.micRequests == 1
                && harness.notificationRequests == 1
                && model.screenPerm == .granted
                && model.micPerm == .granted
                && model.notifPerm == .granted
        }

        XCTAssertTrue(settings.screenPermissionRequested)
    }

    func testLifecycleOutputAgentsAndCompletionPersistence() async throws {
        let harness = Harness(root: try temporaryDirectory("lifecycle"))
        harness.tools["claude"] = "/usr/bin/true"
        harness.tools["kiro-cli"] = "/usr/bin/true"
        var settings = try makeSettings("lifecycle")
        settings.mlxWhisperPath = harness.root.appendingPathComponent("missing").path
        let model = SetupModel(settings: settings, dependencies: harness.dependencies())

        model.beginChecks()
        await waitUntil {
            model.enginePhase == .missing
                && model.claudeFound == true
                && model.kiroFound == true
        }

        let output = try temporaryDirectory("selected-output")
        model.setOutput(output)
        model.setAgentProvider(.kiroCLI)
        model.enginePhase = .done
        model.modelPhase = .done
        model.screenPerm = .granted
        model.micPerm = .granted
        XCTAssertTrue(model.requiredSetupComplete)

        model.finish()

        XCTAssertEqual(model.outputPath, output.path)
        XCTAssertEqual(settings.outputFolder, output)
        XCTAssertEqual(settings.agentConfiguration.provider, .kiroCLI)
        XCTAssertTrue(settings.setupCompleted)

        model.onEnter(.model)
        model.onEnter(.permissions)
        model.onEnter(.cleanup)
        model.onEnter(.output)
        model.cancelWork()
    }

    private enum TestError: Error { case expected }

    private final class Harness: @unchecked Sendable {
        let root: URL
        let managedToolRoot: URL
        let managedBinRoot: URL
        var tools: [String: String] = [:]
        var cachedModels: Set<String> = []
        var revisionError: Error?
        var screenGranted = false
        var microphoneStatus = AVAuthorizationStatus.notDetermined
        var notificationsStatus = UNAuthorizationStatus.notDetermined
        var grantOnRequest = false
        var screenRequests = 0
        var micRequests = 0
        var notificationRequests = 0

        init(root: URL) {
            self.root = root
            managedToolRoot = root.appendingPathComponent("uv-tools", isDirectory: true)
            managedBinRoot = root.appendingPathComponent("bin", isDirectory: true)
        }

        func dependencies() -> SetupModelDependencies {
            SetupModelDependencies(
                findTool: { [self] in tools[$0] },
                isExecutable: {
                    FileManager.default.isExecutableFile(atPath: $0)
                },
                verifyPublishedRevision: { [self] _ in
                    if let revisionError { throw revisionError }
                },
                modelCached: { [self] in cachedModels.contains($0) },
                screenRecordingGranted: { [self] in screenGranted },
                micStatus: { [self] in microphoneStatus },
                notificationStatus: { [self] in notificationsStatus },
                requestScreenRecording: { [self] in
                    screenRequests += 1
                    if grantOnRequest { screenGranted = true }
                    return grantOnRequest
                },
                requestMic: { [self] in
                    micRequests += 1
                    if grantOnRequest { microphoneStatus = .authorized }
                    return grantOnRequest
                },
                requestNotifications: { [self] in
                    notificationRequests += 1
                    if grantOnRequest { notificationsStatus = .authorized }
                    return grantOnRequest
                },
                permissionRefreshDelay: {},
                managedToolRoot: managedToolRoot,
                managedBinRoot: managedBinRoot)
        }
    }

    private func makeSettings(_ label: String) throws -> Settings {
        let suite = "test.meetscribe.setup.\(label).\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        var settings = Settings(defaults: defaults)
        settings.outputFolder = try temporaryDirectory(label)
        return settings
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func makeExecutable(_ contents: String, in root: URL, name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path)
        return url
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition did not become true before timeout")
    }
}
