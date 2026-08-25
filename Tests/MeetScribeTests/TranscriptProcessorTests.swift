import XCTest
@testable import MeetScribe

final class TranscriptProcessorTests: XCTestCase {
    func testLongTranscriptsReceiveExtendedProcessingTimeout() {
        XCTAssertEqual(
            TranscriptProcessorSupport.timeout(for: String(repeating: "a", count: 1_000)),
            300)
        XCTAssertEqual(
            TranscriptProcessorSupport.timeout(for: String(repeating: "a", count: 50_000)),
            900)
    }

    func testCustomCommandReceivesLiteralArgumentsAndRestrictedEnvironment() throws {
        let root = try temporaryDirectory("processor")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-agent")
        let argumentsLog = root.appendingPathComponent("arguments.log")
        let environmentLog = root.appendingPathComponent("environment.log")
        let processed = processedTranscript()
        let script = """
            #!/bin/sh
            printf '<%s>\\n' "$@" > "\(argumentsLog.path)"
            printf '%s' "${AWS_SECRET_ACCESS_KEY-unset}" > "\(environmentLog.path)"
            cat <<'MEETSCRIBE_OUTPUT'
            \(processed)
            MEETSCRIBE_OUTPUT
            """
        try makeExecutable(script, at: executable)
        setenv("AWS_SECRET_ACCESS_KEY", "must-not-leak", 1)
        defer { unsetenv("AWS_SECRET_ACCESS_KEY") }
        let configuration = AgentConfiguration(
            provider: .customCommand,
            customExecutable: executable.path,
            customArguments: ["--prompt={prompt}", "value;not-a-shell-command"],
            customPrompt: "Clean safely",
            inheritEnvironment: false)

        let result = try XCTUnwrap(
            CommandTranscriptProcessor(configuration: configuration).process(originalTranscript()))

        XCTAssertEqual(result.topicSlug, "planning")
        XCTAssertTrue(result.markdown.contains("## Summary"))
        let arguments = try String(contentsOf: argumentsLog, encoding: .utf8)
        XCTAssertTrue(arguments.contains("<--prompt=Clean safely>"))
        XCTAssertTrue(arguments.contains("<value;not-a-shell-command>"))
        XCTAssertEqual(
            try String(contentsOf: environmentLog, encoding: .utf8),
            "unset")
    }

    func testCustomCommandRejectsStructurallyUnsafeOutput() throws {
        let root = try temporaryDirectory("processor-invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("invalid-agent")
        try makeExecutable(
            "#!/bin/sh\nprintf '<!-- topic: planning -->\\nnot a transcript\\n'\n",
            at: executable)
        let configuration = AgentConfiguration(
            provider: .customCommand,
            customExecutable: executable.path,
            customArguments: [],
            customPrompt: "",
            inheritEnvironment: false)

        XCTAssertThrowsError(
            try CommandTranscriptProcessor(configuration: configuration).process(originalTranscript())
        ) { error in
            guard case CommandTranscriptProcessor.ProcessorError.invalidOutput = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testCustomCommandRejectsStructurallyValidOutputWithoutTopic() throws {
        let root = try temporaryDirectory("processor-missing-topic")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("missing-topic-agent")
        let output = processedTranscript()
            .replacingOccurrences(of: "<!-- topic: planning -->\n", with: "")
        let script = """
            #!/bin/sh
            cat <<'MEETSCRIBE_OUTPUT'
            \(output)
            MEETSCRIBE_OUTPUT
            """
        try makeExecutable(script, at: executable)
        let configuration = AgentConfiguration(
            provider: .customCommand,
            customExecutable: executable.path,
            customArguments: [],
            customPrompt: "",
            inheritEnvironment: false)

        XCTAssertThrowsError(
            try CommandTranscriptProcessor(configuration: configuration).process(originalTranscript())
        ) { error in
            guard case CommandTranscriptProcessor.ProcessorError.missingTopic = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testFactoryBuildsConfiguredProvider() throws {
        XCTAssertNil(TranscriptProcessorFactory.make(configuration: .disabled))
        XCTAssertEqual(
            TranscriptProcessorFactory.make(configuration: .claudeCode)?.id,
            "claude-code")
        XCTAssertEqual(
            TranscriptProcessorFactory.make(configuration: .kiroCLI)?.id,
            "kiro-cli")
        var custom = AgentConfiguration.disabled
        custom.provider = .customCommand
        custom.customExecutable = "/bin/cat"
        XCTAssertEqual(
            TranscriptProcessorFactory.make(configuration: custom)?.id,
            "custom-command")
    }

    func testCustomCommandRequiresAbsoluteExecutable() {
        var configuration = AgentConfiguration.disabled
        configuration.provider = .customCommand
        configuration.customExecutable = "relative-agent"

        XCTAssertThrowsError(
            try CommandTranscriptProcessor(configuration: configuration).process(originalTranscript())
        ) { error in
            guard case CommandTranscriptProcessor.ProcessorError.missingExecutable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func originalTranscript() -> String {
        """
        ---
        date: 2026-08-20
        attendees: []
        tags: [meeting, transcript]
        ---

        ## Transcript

        [00:00:01] **Me:** um hello

        <!-- meetscribe: app=manual, duration=00:00:02, model=test, cleaned=false, processor=none -->
        """
    }

    private func processedTranscript() -> String {
        """
        <!-- topic: planning -->
        ---
        date: 2026-08-20
        attendees: []
        tags: [meeting, transcript]
        ---

        ## Summary

        Greeting.

        ## Transcript

        [00:00:01] **Me:** Hello.

        <!-- meetscribe: app=manual, duration=00:00:02, model=test, cleaned=false, processor=none -->
        """
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(_ contents: String, at url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path)
    }
}
