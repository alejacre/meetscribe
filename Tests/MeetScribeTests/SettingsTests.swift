import XCTest
@testable import MeetScribe

final class SettingsTests: XCTestCase {
    func testDestinationValidationRejectsStaleConfigurationAndCancelledEnable() {
        let selectedGit = GitDestinationConfiguration(
            enabled: true,
            repositoryPath: "/tmp/repository-a")
        XCTAssertTrue(DestinationValidation.isCurrent(
            current: GitDestinationConfiguration(
                repositoryPath: "/tmp/repository-a"),
            selected: selectedGit,
            status: .working))
        XCTAssertFalse(DestinationValidation.isCurrent(
            current: GitDestinationConfiguration(
                repositoryPath: "/tmp/repository-b"),
            selected: selectedGit,
            status: .working))
        XCTAssertFalse(DestinationValidation.isCurrent(
            current: GitDestinationConfiguration(
                repositoryPath: "/tmp/repository-a"),
            selected: selectedGit,
            status: .idle))

        let selectedSFTP = SFTPDestinationConfiguration(
            enabled: true,
            host: "archive-a")
        XCTAssertFalse(DestinationValidation.isCurrent(
            current: SFTPDestinationConfiguration(host: "archive-b"),
            selected: selectedSFTP,
            status: .working))
    }

    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "test.meetscribe")!
        defaults.removePersistentDomain(forName: "test.meetscribe")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "test.meetscribe")
        defaults = nil
    }

    func testDefaults() {
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.outputFolder.path, NSHomeDirectory() + "/Recordings")
        XCTAssertEqual(s.whisperModel, "mlx-community/whisper-large-v3-turbo")
        XCTAssertFalse(s.claudeCleanupEnabled)
        XCTAssertFalse(s.screenPermissionRequested)
        XCTAssertTrue(s.mlxWhisperPath.hasSuffix("mlx_whisper"))
        XCTAssertEqual(s.retentionConfiguration, RetentionConfiguration())
        XCTAssertEqual(s.recordingAudioMode, .microphoneAndSystem)
    }

    func testPersistence() {
        var s = Settings(defaults: defaults)
        s.outputFolder = URL(fileURLWithPath: "/tmp/recs")
        s.claudeCleanupEnabled = true
        s.screenPermissionRequested = true
        s.recordingAudioMode = .systemOnly
        let s2 = Settings(defaults: defaults)
        XCTAssertEqual(s2.outputFolder.path, "/tmp/recs")
        XCTAssertTrue(s2.claudeCleanupEnabled)
        XCTAssertTrue(s2.screenPermissionRequested)
        XCTAssertEqual(s2.recordingAudioMode, .systemOnly)
    }

    func testUnknownPersistedAudioModeFallsBackToDefault() {
        defaults.set("hologram", forKey: "recordingAudioMode")
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.recordingAudioMode, .microphoneAndSystem)
    }

    func testChangingOutputFolderPostsNotification() {
        let notification = expectation(
            forNotification: Settings.outputFolderChanged,
            object: nil)
        var settings = Settings(defaults: defaults)

        settings.outputFolder = URL(fileURLWithPath: "/tmp/changed-recordings")

        wait(for: [notification], timeout: 1)
    }

    func testSetupCompletedDefaultsFalseAndPersists() {
        var s = Settings(defaults: defaults)
        XCTAssertFalse(s.setupCompleted)
        s.setupCompleted = true
        XCTAssertTrue(Settings(defaults: defaults).setupCompleted)
    }

    func testMigratesLegacyClaudeToggle() {
        defaults.set(true, forKey: "claudeCleanupEnabled")

        let settings = Settings(defaults: defaults)

        XCTAssertEqual(settings.agentConfiguration, .claudeCode)
    }

    func testPersistsExtensibleConfiguration() {
        var settings = Settings(defaults: defaults)
        let customRule = MeetingRule(
            bundleID: "dev.example.meeting",
            displayName: "Example Meeting",
            appName: "example",
            policy: .automatic)
        let agent = AgentConfiguration(
            provider: .customCommand,
            customExecutable: "/usr/local/bin/transcript-agent",
            customArguments: ["--prompt", "{prompt}"],
            customPrompt: "Clean this transcript",
            inheritEnvironment: true)
        let destinations = DestinationConfiguration(
            git: GitDestinationConfiguration(
                enabled: true,
                repositoryPath: "/tmp/notes",
                relativePath: "meetings",
                includeManifest: true,
                includeRawTranscript: true,
                includeAudio: false),
            sftp: SFTPDestinationConfiguration(
                enabled: true,
                host: "archive",
                remotePath: "/srv/recordings",
                includeManifest: true,
                includeAudio: true))
        let retention = RetentionConfiguration(
            deleteSourceTracksAfterTranscription: true,
            audioRetentionDays: 30,
            rawTranscriptRetentionDays: 7)

        settings.meetingRules = [customRule]
        settings.agentConfiguration = agent
        settings.destinationConfiguration = destinations
        settings.retentionConfiguration = retention

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(
            reloaded.meetingRules.first { $0.bundleID == customRule.bundleID },
            customRule)
        XCTAssertEqual(reloaded.agentConfiguration, agent)
        XCTAssertEqual(reloaded.destinationConfiguration, destinations)
        XCTAssertEqual(reloaded.retentionConfiguration, retention)
    }

    func testDestinationConfigurationDecodesLegacyExportDefaults() throws {
        let data = Data("""
        {
          "git": {
            "enabled": true,
            "repositoryPath": "/tmp/notes",
            "relativePath": "meetings",
            "includeAudio": false
          },
          "sftp": {
            "enabled": false,
            "host": "",
            "remotePath": "",
            "includeAudio": false
          }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(DestinationConfiguration.self, from: data)

        XCTAssertFalse(decoded.git.includeManifest)
        XCTAssertFalse(decoded.git.includeRawTranscript)
        XCTAssertFalse(decoded.sftp.includeManifest)
        XCTAssertFalse(decoded.sftp.includeRawTranscript)
    }

    func testConfigurationLabelsMergingAndDestinationState() {
        XCTAssertEqual(RecordingStartPolicy.ignore.displayName, "Ignore")
        XCTAssertEqual(RecordingStartPolicy.ask.displayName, "Ask before recording")
        XCTAssertEqual(RecordingStartPolicy.automatic.displayName, "Record automatically")
        XCTAssertEqual(AgentProviderKind.disabled.displayName, "None")
        XCTAssertEqual(AgentProviderKind.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(AgentProviderKind.kiroCLI.displayName, "Kiro CLI")
        XCTAssertEqual(AgentProviderKind.customCommand.displayName, "Custom command")
        XCTAssertEqual(
            RecordingAudioMode.microphoneAndSystem.displayName,
            "Computer + microphone")
        XCTAssertEqual(
            RecordingAudioMode.systemOnly.displayName,
            "Computer audio only")
        XCTAssertTrue(RecordingAudioMode.microphoneAndSystem.capturesMicrophone)
        XCTAssertFalse(RecordingAudioMode.systemOnly.capturesMicrophone)

        let replacement = MeetingRule(
            bundleID: "us.zoom.xos",
            displayName: "Zoom replacement",
            appName: "zoom-custom",
            policy: .automatic)
        let custom = MeetingRule(
            bundleID: "dev.example.call",
            displayName: "Example Call",
            appName: "example-call",
            policy: .ignore)
        let merged = MeetingApps.merged(with: [replacement, custom])
        XCTAssertEqual(merged.first { $0.bundleID == replacement.bundleID }, replacement)
        XCTAssertEqual(merged.first { $0.bundleID == custom.bundleID }, custom)

        var destinations = DestinationConfiguration()
        XCTAssertFalse(destinations.hasEnabledDestination)
        destinations.sftp.enabled = true
        XCTAssertTrue(destinations.hasEnabledDestination)
    }
}
