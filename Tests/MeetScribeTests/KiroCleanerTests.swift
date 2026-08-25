import XCTest
@testable import MeetScribe

final class KiroCleanerTests: XCTestCase {
    func testExtractMarkdownStripsKiroFraming() {
        let output = """
            \u{001B}[mWARNING: ignored
            ------

            \u{001B}[m> \u{001B}[0m<!-- topic: planning -->
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            date: 2026-08-20
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            \u{001B}[m\u{001B}[1m## Summary\u{001B}[0m
            Summary.

            \u{001B}[m\u{001B}[1m## Transcript\u{001B}[0m
            [00:00:01] \u{001B}[1mMe:\u{001B}[22m Hello.

            <!-- meetscribe: app=manual, duration=00:00:02, model=test, cleaned=false, processor=none -->

             ▸ Credits: 1.0
            """

        let markdown = KiroCleaner.extractMarkdown(from: output)

        XCTAssertTrue(markdown.hasPrefix("<!-- topic: planning -->"))
        XCTAssertTrue(markdown.contains("---\ndate: 2026-08-20\n---"))
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("[00:00:01] **Me:** Hello."))
        XCTAssertFalse(markdown.contains("Credits:"))
        XCTAssertFalse(markdown.contains("\u{001B}"))
    }

    func testLiveKiroSmokeWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MEETSCRIBE_LIVE_KIRO"] == "1" else {
            throw XCTSkip("Set MEETSCRIBE_LIVE_KIRO=1 to run the authenticated Kiro smoke test.")
        }

        let result = try XCTUnwrap(KiroCleaner.clean(originalTranscript()))

        XCTAssertFalse(result.topicSlug.isEmpty)
        XCTAssertTrue(result.markdown.contains("## Summary"))
        XCTAssertTrue(result.markdown.contains("[00:00:01] **Me:**"))
    }

    func testCleanUsesToolFreeAgentAndDeletesTemporarySession() throws {
        let root = try temporaryDirectory("kiro-cleaner")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-kiro")
        let argumentsLog = root.appendingPathComponent("arguments.log")
        let stdinLog = root.appendingPathComponent("stdin.log")
        let environmentLog = root.appendingPathComponent("environment.log")
        let workspaceLog = root.appendingPathComponent("workspace.log")
        let agentLog = root.appendingPathComponent("agent.json")
        let deletionLog = root.appendingPathComponent("deletion.log")
        let processed = processedTranscript()
        let script = """
            #!/bin/sh
            case " $* " in
              *" --list-sessions "*)
                printf '[{"sessions":[{"sessionId":"temporary-session"}]}]'
                exit 0
                ;;
              *" --delete-session "*)
                printf '%s' "$3" > "\(deletionLog.path)"
                exit 0
                ;;
            esac
            printf '<%s>\\n' "$@" > "\(argumentsLog.path)"
            cat > "\(stdinLog.path)"
            printf '%s' "${AWS_SECRET_ACCESS_KEY-unset}" > "\(environmentLog.path)"
            pwd > "\(workspaceLog.path)"
            cp "$PWD/.kiro/agents/\(KiroCleaner.agentName).json" "\(agentLog.path)"
            printf '\\033[m> \\033[0m'
            cat <<'MEETSCRIBE_OUTPUT'
            \(processed)
            MEETSCRIBE_OUTPUT
            printf '\\n ▸ Credits: 0.1 • Time: 1s\\n'
            """
        try makeExecutable(script, at: executable)
        setenv("AWS_SECRET_ACCESS_KEY", "must-not-leak", 1)
        defer { unsetenv("AWS_SECRET_ACCESS_KEY") }

        let result = try XCTUnwrap(
            KiroCleaner.clean(originalTranscript(), binary: executable.path))

        XCTAssertEqual(result.topicSlug, "planning")
        XCTAssertTrue(result.markdown.contains("## Summary"))
        let arguments = try String(contentsOf: argumentsLog, encoding: .utf8)
        XCTAssertTrue(arguments.contains("<chat>"))
        XCTAssertTrue(arguments.contains("<--agent>"))
        XCTAssertTrue(arguments.contains("<\(KiroCleaner.agentName)>"))
        XCTAssertTrue(arguments.contains("<--no-interactive>"))
        XCTAssertTrue(arguments.contains("<--wrap>"))
        XCTAssertTrue(arguments.contains("<never>"))
        XCTAssertFalse(arguments.contains("Transcript follows:"))
        XCTAssertTrue(
            try String(contentsOf: stdinLog, encoding: .utf8)
                .contains("Transcript follows:"))
        XCTAssertEqual(
            try String(contentsOf: environmentLog, encoding: .utf8),
            "unset")
        XCTAssertTrue(
            try String(contentsOf: agentLog, encoding: .utf8)
                .contains(#""tools": []"#))
        XCTAssertEqual(
            try String(contentsOf: deletionLog, encoding: .utf8),
            "temporary-session")
        let workspace = try String(contentsOf: workspaceLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace))
    }

    func testConfiguredMissingBinaryFailsExplicitly() {
        XCTAssertThrowsError(
            try KiroCleaner.clean(originalTranscript(), binary: "/missing/kiro-cli")
        ) { error in
            XCTAssertEqual(error as? KiroCleaner.CleanError, .unavailable)
        }
    }

    func testCleanFailsWhenTemporarySessionCannotBeDeleted() throws {
        let root = try temporaryDirectory("kiro-cleanup-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-kiro")
        let script = """
            #!/bin/sh
            case " $* " in
              *" --list-sessions "*)
                printf '[{"sessions":[{"sessionId":"temporary-session"}]}]'
                exit 0
                ;;
              *" --delete-session "*)
                printf 'cannot delete session' >&2
                exit 1
                ;;
            esac
            cat <<'MEETSCRIBE_OUTPUT'
            \(processedTranscript())
            MEETSCRIBE_OUTPUT
            """
        try makeExecutable(script, at: executable)

        XCTAssertThrowsError(
            try KiroCleaner.clean(originalTranscript(), binary: executable.path)
        ) { error in
            XCTAssertEqual(
                error as? KiroCleaner.CleanError,
                .sessionCleanupFailed)
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meetscribe-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(_ script: String, at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path)
    }
}
