import AVFoundation
import SwiftUI
import UserNotifications
import XCTest
@testable import MeetScribe

@MainActor
final class ViewRenderingTests: XCTestCase {
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

    func testSettingsPanesBuildAllConditionalStates() throws {
        let settings = try makeSettings("settings-panes")
        evaluate(GeneralSettingsPane(
            settings: settings,
            outputPath: settings.outputFolder.path,
            model: "unsupported/model",
            whisperPath: "/tmp/mlx_whisper",
            hotKeyOn: false,
            launchAtLogin: true,
            configurationError: "Configuration failed"))

        evaluate(AgentSettingsPane(settings: settings, configuration: .disabled, loaded: true))
        evaluate(AgentSettingsPane(settings: settings, configuration: .claudeCode, loaded: true))
        evaluate(AgentSettingsPane(
            settings: settings,
            configuration: AgentConfiguration(
                provider: .customCommand,
                customExecutable: "/usr/bin/cat",
                customArguments: ["--prompt={prompt}"],
                customPrompt: "Clean",
                inheritEnvironment: false),
            argumentsText: "--prompt={prompt}",
            loaded: true))
        evaluate(AgentSettingsPane(
            settings: settings,
            configuration: AgentConfiguration(
                provider: .customCommand,
                customExecutable: "/usr/bin/cat",
                customArguments: [],
                customPrompt: "Clean",
                inheritEnvironment: true),
            loaded: true))

        let customRule = MeetingRule(
            bundleID: "dev.example.meeting",
            displayName: "Example Meeting",
            appName: "example",
            policy: .automatic)
        evaluate(TriggerSettingsPane(
            settings: settings,
            rules: MeetingApps.defaults + [customRule],
            customBundleID: "invalid",
            customName: "Example",
            error: "Use a unique bundle identifier"))

        evaluate(DestinationSettingsPane(settings: settings))
        let enabled = DestinationConfiguration(
            git: GitDestinationConfiguration(
                enabled: true,
                repositoryPath: "/tmp/repository",
                relativePath: "meetings",
                includeAudio: true),
            sftp: SFTPDestinationConfiguration(
                enabled: true,
                host: "archive",
                remotePath: "/srv/recordings",
                includeAudio: true))
        evaluate(DestinationSettingsPane(
            settings: settings,
            configuration: enabled,
            loaded: true,
            gitStatus: .working,
            sftpStatus: .success("Connection ready")))
        evaluate(DestinationSettingsPane(
            settings: settings,
            configuration: enabled,
            loaded: true,
            gitStatus: .failure("Repository unavailable"),
            sftpStatus: .idle))
        evaluate(SettingsView())
    }

    func testSearchViewBuildsEmptyAndPopulatedResults() throws {
        evaluate(SearchView())
        evaluate(SearchView(query: "missing", searched: true))

        let root = try temporaryDirectory("search-view")
        let note = root.appendingPathComponent("meeting.md")
        let hit = SearchHit(folder: note, file: note, line: "A matching line")
        evaluate(SearchView(query: "matching", hits: [hit], searched: true))
    }

    func testRecordingsViewBuilds() throws {
        let root = try temporaryDirectory("recordings-view")
        let state = AppState()

        evaluate(RecordingsView(state: state, root: root))
    }

    func testRecordingBrowserRowsAndTranscriptStatesBuild() throws {
        let root = try temporaryDirectory("recordings-content")
        let session = RecordingSession(
            root: root,
            start: Date(),
            appName: "zoom")
        try session.createFolder()
        let markdown = """
        ---
        date: 2026-08-20
        tags: [meeting, transcript]
        ---

        ## Summary
        The release checks are green.

        ## Decisions
        - Publish real screenshots.

        ## Transcript
        [00:00:02] **Me:** Let's review the release.
        [00:00:06] **Them:** The build is green.

        <!-- meetscribe: app=zoom, duration=00:12:48, model=test, cleaned=true, processor=test -->
        """
        try markdown.write(to: session.noteURL, atomically: true, encoding: .utf8)
        let record = RecordingRecord(
            noteURL: session.noteURL,
            assetDir: session.assetDir,
            modifiedAt: Date(),
            manifest: RecordingManifestStore.loadIfPresent(from: session.manifestURL))
        let document = TranscriptDocument.parse(
            markdown,
            filename: "2026-08-20-product-review")

        evaluate(RecordingRow(record: record, document: document))
        evaluate(TranscriptDetailView(record: record, document: document))
        evaluate(TranscriptTurnRow(turn: document.turns[0]))
        evaluate(TranscriptTurnRow(turn: document.turns[1]))
        let warningRecord = RecordingRecord(
            noteURL: record.noteURL,
            assetDir: record.assetDir,
            modifiedAt: record.modifiedAt,
            manifest: record.manifest,
            manifestError: "The manifest is not valid JSON.")
        evaluate(RecordingRow(record: warningRecord, document: document))
        evaluate(TranscriptDetailView(record: warningRecord, document: document))

        let failed = RecordingSession(
            root: root,
            start: Date().addingTimeInterval(-60),
            appName: "manual")
        try failed.createFolder()
        let failedRecord = RecordingRecord(
            noteURL: failed.noteURL,
            assetDir: failed.assetDir,
            modifiedAt: Date(),
            manifest: nil)
        evaluate(RecordingRow(record: failedRecord, document: nil))

        let legacy = TranscriptDocument.parse(
            "## Transcript\nLegacy content without timestamped turns.",
            filename: "2026-08-19-legacy")
        evaluate(TranscriptDetailView(record: record, document: legacy))
    }

    func testSetupViewBuildsEveryStepAndPhase() throws {
        let settings = try makeSettings("setup-view")
        let model = SetupModel(
            settings: settings,
            dependencies: dependencies())

        model.step = SetupStep.welcome
        evaluate(SetupView(model: model))

        model.step = SetupStep.engine
        for phase in [
            StepPhase.checking,
            .done,
            .missing,
            .working,
            .failed("Engine failed"),
        ] {
            model.enginePhase = phase
            model.resolvedEnginePath = "/tmp/mlx_whisper"
            model.engineLog = "install log"
            model.engineProgress = phase == StepPhase.working ? 42 : nil
            evaluate(SetupView(model: model))
        }

        model.step = SetupStep.model
        for phase in [
            StepPhase.checking,
            .done,
            .missing,
            .working,
            .failed("Model failed"),
        ] {
            model.modelPhase = phase
            model.modelLog = "download log"
            model.modelProgress = phase == StepPhase.working ? 73 : nil
            model.enginePhase = phase == StepPhase.missing ? StepPhase.missing : StepPhase.done
            evaluate(SetupView(model: model))
        }

        model.step = SetupStep.permissions
        model.screenPerm = PermState.unknown
        model.micPerm = PermState.denied
        model.notifPerm = PermState.granted
        evaluate(SetupView(model: model))
        model.screenPerm = PermState.granted
        model.micPerm = PermState.granted
        model.notifPerm = PermState.unknown
        evaluate(SetupView(model: model))

        model.step = SetupStep.output
        evaluate(SetupView(model: model))

        model.step = SetupStep.cleanup
        for found in [nil, true, false] as [Bool?] {
            model.claudeFound = found
            model.claudeEnabled = found == true
            evaluate(SetupView(model: model))
        }

        model.step = SetupStep.done
        evaluate(SetupView(model: model))

        evaluate(ProgressLogView(log: "", progress: nil, caption: nil))
        evaluate(ProgressLogView(log: "working", progress: nil, caption: "Installing"))
        evaluate(ProgressLogView(log: "50%", progress: 50, caption: "Downloading"))
    }

    func testMenuSceneBuildsOperationalStates() throws {
        let state = AppState()
        let coordinator = RecordingCoordinator(
            state: state,
            enableSystemIntegrations: false)
        let app = MeetScribeApp(state: state, coordinator: coordinator)

        state.phase = .idle
        evaluate(app)
        state.phase = .starting
        evaluate(app)
        state.phase = .recording
        state.elapsedSeconds = 65
        evaluate(app)
        state.phase = .stopping
        evaluate(app)

        state.phase = .idle
        state.transcribingCount = 2
        state.publishingCount = 1
        state.lastError = "Permission failed"
        state.showPermissionHelp = true
        state.isQuitting = true
        let root = try temporaryDirectory("menu-recording")
        let session = RecordingSession(root: root, start: Date(), appName: "zoom")
        try session.createFolder()
        state.recentRecordings = [
            RecordingRecord(
                noteURL: session.noteURL,
                assetDir: session.assetDir,
                modifiedAt: Date(),
                manifest: nil)
        ]
        evaluate(app)
    }

    private func evaluate<V: View>(_ view: V) {
        XCTAssertFalse(String(describing: view.body).isEmpty)
    }

    private func evaluate<A: App>(_ app: A) {
        XCTAssertFalse(String(describing: app.body).isEmpty)
    }

    private func makeSettings(_ label: String) throws -> MeetScribe.Settings {
        let suite = "test.meetscribe.views.\(label).\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        var settings = MeetScribe.Settings(defaults: defaults)
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

    private func dependencies() -> SetupModelDependencies {
        SetupModelDependencies(
            findTool: { _ in nil },
            isExecutable: { _ in false },
            verifyPublishedRevision: { _ in },
            modelCached: { _ in false },
            screenRecordingGranted: { false },
            micStatus: { .notDetermined },
            notificationStatus: { .notDetermined },
            requestScreenRecording: { false },
            requestMic: { false },
            requestNotifications: { false },
            permissionRefreshDelay: {},
            managedToolRoot: FileManager.default.temporaryDirectory,
            managedBinRoot: FileManager.default.temporaryDirectory)
    }
}
