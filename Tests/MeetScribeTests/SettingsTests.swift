import XCTest
@testable import MeetScribe

final class SettingsTests: XCTestCase {
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
    }

    func testPersistence() {
        var s = Settings(defaults: defaults)
        s.outputFolder = URL(fileURLWithPath: "/tmp/recs")
        s.claudeCleanupEnabled = true
        s.screenPermissionRequested = true
        let s2 = Settings(defaults: defaults)
        XCTAssertEqual(s2.outputFolder.path, "/tmp/recs")
        XCTAssertTrue(s2.claudeCleanupEnabled)
        XCTAssertTrue(s2.screenPermissionRequested)
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
                includeAudio: false),
            sftp: SFTPDestinationConfiguration(
                enabled: true,
                host: "archive",
                remotePath: "/srv/recordings",
                includeAudio: true))

        settings.meetingRules = [customRule]
        settings.agentConfiguration = agent
        settings.destinationConfiguration = destinations

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(
            reloaded.meetingRules.first { $0.bundleID == customRule.bundleID },
            customRule)
        XCTAssertEqual(reloaded.agentConfiguration, agent)
        XCTAssertEqual(reloaded.destinationConfiguration, destinations)
    }

    func testConfigurationLabelsMergingAndDestinationState() {
        XCTAssertEqual(RecordingStartPolicy.ignore.displayName, "Ignore")
        XCTAssertEqual(RecordingStartPolicy.ask.displayName, "Ask before recording")
        XCTAssertEqual(RecordingStartPolicy.automatic.displayName, "Record automatically")
        XCTAssertEqual(AgentProviderKind.disabled.displayName, "None")
        XCTAssertEqual(AgentProviderKind.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(AgentProviderKind.customCommand.displayName, "Custom command")

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
