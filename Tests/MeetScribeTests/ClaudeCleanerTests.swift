import XCTest
@testable import MeetScribe

final class ClaudeCleanerTests: XCTestCase {
    func testExtractTopic() {
        let (slug, body) = ClaudeCleaner.extractTopic("<!-- topic: q3-budget-review -->\n# Meeting transcript  -  x\nrest")
        XCTAssertEqual(slug, "q3-budget-review")
        XCTAssertTrue(body.hasPrefix("# Meeting transcript"))
        XCTAssertFalse(body.contains("<!-- topic"))
    }

    func testExtractTopicSanitizes() {
        let (slug, _) = ClaudeCleaner.extractTopic("<!-- topic: Q3 Budget! Review -->\nbody")
        XCTAssertEqual(slug, "q3-budget-review")
    }

    func testExtractTopicRejectsUnboundedFilenames() {
        XCTAssertNil(ClaudeCleaner.extractTopic(
            "<!-- topic: one-two-three-four -->\nbody").0)
        XCTAssertNil(ClaudeCleaner.extractTopic(
            "<!-- topic: \(String(repeating: "a", count: 65)) -->\nbody").0)
    }

    func testIsLoginFailure() {
        XCTAssertTrue(ClaudeCleaner.isLoginFailure("Not logged in · Please run /login"))
        XCTAssertTrue(ClaudeCleaner.isLoginFailure("Please run /login"))
        XCTAssertFalse(ClaudeCleaner.isLoginFailure("<!-- topic: standup -->\n---\ndate: 2026-07-24"))
    }

    func testNoTopicLine() {
        let (slug, body) = ClaudeCleaner.extractTopic("# Meeting transcript  -  x\nrest\n")
        XCTAssertNil(slug)
        XCTAssertTrue(body.hasPrefix("# Meeting transcript"))
    }

    func testStructuralValidationAcceptsSummaryAndCleanedBody() {
        let original = transcript("[00:00:01] **Me:** um hello")
        let cleaned = cleanedTranscript("[00:00:01] **Me:** Hello.")
        XCTAssertTrue(ClaudeCleaner.structurallyValid(original: original, cleaned: cleaned))
    }

    func testStructuralValidationRejectsDroppedTurn() {
        let original = transcript("""
        [00:00:01] **Me:** Hello.
        [00:00:02] **Them:** Hi.
        """)
        let cleaned = cleanedTranscript("[00:00:01] **Me:** Hello.")
        XCTAssertFalse(ClaudeCleaner.structurallyValid(original: original, cleaned: cleaned))
    }

    func testStructuralValidationRejectsChangedMetadata() {
        let original = transcript("[00:00:01] **Me:** Hello.")
        let cleaned = cleanedTranscript("[00:00:01] **Me:** Hello.")
            .replacingOccurrences(of: "model=test", with: "model=other")
        XCTAssertFalse(ClaudeCleaner.structurallyValid(original: original, cleaned: cleaned))
    }

    func testStructuralValidationRejectsReplacedTranscriptText() {
        let original = transcript("""
        [00:00:01] **Me:** We approved the launch for Friday.
        [00:00:02] **Them:** I will prepare the customer migration.
        """)
        let cleaned = cleanedTranscript("""
        [00:00:01] **Me:** Completely unrelated invented sentence.
        [00:00:02] **Them:** Another fabricated response appears here.
        """)

        XCTAssertFalse(ClaudeCleaner.structurallyValid(original: original, cleaned: cleaned))
    }

    func testStructuralValidationRejectsPartialTranscriptLoss() {
        let original = transcript("""
        [00:00:01] **Me:** We reviewed the launch plan customer migration rollback monitoring and ownership.
        [00:00:02] **Them:** The team confirmed testing documentation support staffing and release timing.
        """)
        let cleaned = cleanedTranscript("""
        [00:00:01] **Me:** We reviewed the launch plan.
        [00:00:02] **Them:** The team confirmed testing documentation.
        """)

        XCTAssertFalse(ClaudeCleaner.structurallyValid(original: original, cleaned: cleaned))
    }

    func testConfiguredMissingBinaryFailsExplicitly() {
        XCTAssertThrowsError(
            try ClaudeCleaner.clean(
                transcript("[00:00:01] **Me:** Hello."),
                binary: "/missing/claude")
        ) { error in
            XCTAssertEqual(error as? ClaudeCleaner.CleanError, .unavailable)
        }
    }

    func testCleanUsesRestrictedToolFreeInvocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-claude-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-claude")
        let argsLog = root.appendingPathComponent("args.log")
        let envLog = root.appendingPathComponent("env.log")
        let cleaned = """
        <!-- topic: planning -->
        ---
        date: 2026-07-28
        attendees: []
        tags: [meeting, transcript]
        ---

        ## Summary

        Greeting.

        ## Transcript

        [00:00:01] **Me:** Hello.

        <!-- meetscribe: app=manual, duration=00:00:02, model=test, cleaned=false -->
        """
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argsLog.path)"
        printf '%s' "${AWS_SECRET_ACCESS_KEY-unset}" > "\(envLog.path)"
        cat <<'MEETSCRIBE_OUTPUT'
        \(cleaned)
        MEETSCRIBE_OUTPUT
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path)
        setenv("AWS_SECRET_ACCESS_KEY", "must-not-leak", 1)
        defer { unsetenv("AWS_SECRET_ACCESS_KEY") }

        let result = try XCTUnwrap(ClaudeCleaner.clean(
            transcript("[00:00:01] **Me:** um hello"),
            binary: executable.path))

        XCTAssertEqual(result.topicSlug, "planning")
        XCTAssertTrue(result.markdown.contains("## Summary"))
        let args = try String(contentsOf: argsLog, encoding: .utf8)
        XCTAssertTrue(args.contains("--model\n\(ClaudeCleaner.model)\n"))
        XCTAssertTrue(args.contains("--tools\n\n"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertEqual(try String(contentsOf: envLog, encoding: .utf8), "unset")
    }

    func testCleanRejectsStructurallyValidOutputWithoutTopic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-claude-topic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-claude")
        let script = """
        #!/bin/sh
        cat <<'MEETSCRIBE_OUTPUT'
        \(cleanedTranscript("[00:00:01] **Me:** Hello."))
        MEETSCRIBE_OUTPUT
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path)

        XCTAssertThrowsError(try ClaudeCleaner.clean(
            transcript("[00:00:01] **Me:** um hello"),
            binary: executable.path)
        ) { error in
            guard case ClaudeCleaner.CleanError.missingTopic = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLiveClaudeHaikuSmokeWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MEETSCRIBE_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("Set MEETSCRIBE_LIVE_CLAUDE=1 to run the authenticated Claude smoke test.")
        }

        let result = try XCTUnwrap(ClaudeCleaner.clean(
            transcript(
                """
                [00:00:01] **Me:** um hello everyone
                [00:00:04] **Them:** hi we should review the test plan
                """)))

        XCTAssertFalse(result.topicSlug.isEmpty)
        XCTAssertTrue(result.markdown.contains("## Summary"))
        XCTAssertTrue(result.markdown.contains("[00:00:01] **Me:**"))
        XCTAssertTrue(result.markdown.contains("[00:00:04] **Them:**"))
    }

    private func transcript(_ body: String) -> String {
        """
        ---
        date: 2026-07-28
        attendees: []
        tags: [meeting, transcript]
        ---

        ## Transcript

        \(body)

        <!-- meetscribe: app=manual, duration=00:00:02, model=test, cleaned=false -->
        """
    }

    private func cleanedTranscript(_ body: String) -> String {
        """
        ---
        date: 2026-07-28
        attendees: []
        tags: [meeting, transcript]
        ---

        ## Summary

        Greeting.

        ## Transcript

        \(body)

        <!-- meetscribe: app=manual, duration=00:00:02, model=test, cleaned=false -->
        """
    }
}
