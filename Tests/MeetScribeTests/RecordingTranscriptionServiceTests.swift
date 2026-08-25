import XCTest
@testable import MeetScribe

final class RecordingTranscriptionServiceTests: XCTestCase {
    func testRunWritesTranscriptArtifactsAndMarksManifestReady() throws {
        let root = try temporaryDirectory("transcription-service")
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_777_003_200)
        let session = RecordingSession(
            root: root,
            start: start,
            appName: "teams",
            bundleID: "com.microsoft.teams2",
            trigger: .meetingPrompt)
        try session.createFolder()
        let configuration = RecordingTranscriptionConfiguration(
            mlxWhisperPath: "/unused",
            whisperModel: "test/model",
            agentConfiguration: .disabled)
        let tracks = RecordingTrackTranscriber { _, _ in
            TranscriptionTracks(
                mic: [WhisperSegment(start: 1, end: 2, text: "Hello")],
                system: [WhisperSegment(start: 3, end: 4, text: "Welcome")])
        }

        let result = try RecordingTranscriptionService.run(
            session: session,
            configuration: configuration,
            trackTranscriber: tracks)

        let markdown = try String(
            contentsOf: result.finalSession.noteURL,
            encoding: .utf8)
        let manifest = try RecordingManifestStore.load(
            from: result.finalSession.manifestURL)
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: result.finalSession.transcriptJSON))
        XCTAssertTrue(markdown.contains("[00:00:01] **Me:** Hello"))
        XCTAssertTrue(markdown.contains("[00:00:03] **Them:** Welcome"))
        XCTAssertNotNil(raw as? [String: Any])
        XCTAssertEqual(manifest.lifecycle, .ready)
        XCTAssertEqual(manifest.transcript?.model, "test/model")
        XCTAssertNil(manifest.transcript?.processorID)
        XCTAssertNil(result.processingWarning)
    }

    func testRunAppliesOptInSourceTrackRetention() throws {
        let root = try temporaryDirectory("transcription-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(root: root, start: Date(), appName: "teams")
        try session.createFolder()
        try Data("mic".utf8).write(to: session.micURL)
        try Data("system".utf8).write(to: session.systemURL)
        let configuration = RecordingTranscriptionConfiguration(
            mlxWhisperPath: "/unused",
            whisperModel: "test/model",
            agentConfiguration: .disabled,
            retentionConfiguration: RetentionConfiguration(
                deleteSourceTracksAfterTranscription: true))

        let result = try RecordingTranscriptionService.run(
            session: session,
            configuration: configuration,
            trackTranscriber: testTracks())

        XCTAssertFalse(FileManager.default.fileExists(atPath: result.finalSession.micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.finalSession.systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.finalSession.noteURL.path))
    }

    func testRunKeepsRawTranscriptWhenAgentFails() throws {
        let root = try temporaryDirectory("transcription-agent-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(
            root: root,
            start: Date(),
            appName: nil)
        try session.createFolder()
        let configuration = RecordingTranscriptionConfiguration(
            mlxWhisperPath: "/unused",
            whisperModel: "test/model",
            agentConfiguration: AgentConfiguration(
                provider: .customCommand,
                customExecutable: "/missing/transcript-agent",
                customArguments: [],
                customPrompt: "",
                inheritEnvironment: false))
        let tracks = RecordingTrackTranscriber { _, _ in
            TranscriptionTracks(
                mic: [WhisperSegment(start: 0, end: 1, text: "Raw words")],
                system: [])
        }

        let result = try RecordingTranscriptionService.run(
            session: session,
            configuration: configuration,
            trackTranscriber: tracks)

        let markdown = try String(
            contentsOf: result.finalSession.noteURL,
            encoding: .utf8)
        let manifest = try RecordingManifestStore.load(
            from: result.finalSession.manifestURL)
        XCTAssertTrue(markdown.contains("Raw words"))
        XCTAssertEqual(
            result.processingWarning,
            CommandTranscriptProcessor.ProcessorError.missingExecutable.errorDescription)
        XCTAssertEqual(manifest.lifecycle, .ready)
        XCTAssertNil(manifest.transcript?.processorID)
    }

    func testRunKeepsProvisionalNameAndWarnsWhenAgentOmitsTopic() throws {
        let root = try temporaryDirectory("transcription-agent-missing-topic")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("missing-topic-agent")
        let script = """
            #!/bin/sh
            /usr/bin/awk '
                {
                    print
                    if ($0 == "---") {
                        frontmatterMarkers++
                        if (frontmatterMarkers == 2) {
                            print ""
                            print "## Summary"
                            print ""
                            print "Greeting."
                        }
                    }
                }
            '
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path)
        let session = RecordingSession(
            root: root,
            start: Date(timeIntervalSince1970: 1_777_003_200),
            appName: "zoom")
        try session.createFolder()
        let configuration = RecordingTranscriptionConfiguration(
            mlxWhisperPath: "/unused",
            whisperModel: "test/model",
            agentConfiguration: AgentConfiguration(
                provider: .customCommand,
                customExecutable: executable.path,
                customArguments: [],
                customPrompt: "",
                inheritEnvironment: false))
        let tracks = RecordingTrackTranscriber { _, _ in
            TranscriptionTracks(
                mic: [WhisperSegment(start: 0, end: 1, text: "Raw words")],
                system: [])
        }

        let result = try RecordingTranscriptionService.run(
            session: session,
            configuration: configuration,
            trackTranscriber: tracks)

        let markdown = try String(
            contentsOf: result.finalSession.noteURL,
            encoding: .utf8)
        let manifest = try RecordingManifestStore.load(
            from: result.finalSession.manifestURL)
        XCTAssertEqual(result.finalSession.basename, session.basename)
        XCTAssertEqual(
            result.processingWarning,
            CommandTranscriptProcessor.ProcessorError.missingTopic.errorDescription)
        XCTAssertTrue(markdown.contains("Raw words"))
        XCTAssertFalse(markdown.contains("## Summary"))
        XCTAssertNil(manifest.transcript?.processorID)
    }

    func testRunKeepsRawTranscriptWhenFinalRenameFails() throws {
        let root = try temporaryDirectory("transcription-agent-rename-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("valid-agent")
        try makeValidAgent(at: executable)
        let session = RecordingSession(
            root: root,
            start: Date(timeIntervalSince1970: 1_777_003_200),
            appName: "zoom")
        try session.createFolder()
        let configuration = agentConfiguration(executable: executable)
        let tracks = testTracks()
        let finalizer = RecordingFinalizerRunner { _, _ in
            throw TestError.renameFailed
        }

        let result = try RecordingTranscriptionService.run(
            session: session,
            configuration: configuration,
            trackTranscriber: tracks,
            finalizer: finalizer)

        let markdown = try String(contentsOf: session.noteURL, encoding: .utf8)
        let manifest = try RecordingManifestStore.load(from: session.manifestURL)
        XCTAssertEqual(result.finalSession.basename, session.basename)
        XCTAssertEqual(result.processingWarning, TestError.renameFailed.errorDescription)
        XCTAssertTrue(markdown.contains("Raw words"))
        XCTAssertFalse(markdown.contains("## Summary"))
        XCTAssertNil(result.processorID)
        XCTAssertNil(manifest.transcript?.processorID)
    }

    func testRunRenamesBeforeCommittingProcessedTranscript() throws {
        let root = try temporaryDirectory("transcription-agent-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("valid-agent")
        try makeValidAgent(at: executable)
        let session = RecordingSession(
            root: root,
            start: Date(timeIntervalSince1970: 1_777_003_200),
            appName: "zoom")
        try session.createFolder()

        let result = try RecordingTranscriptionService.run(
            session: session,
            configuration: agentConfiguration(executable: executable),
            trackTranscriber: testTracks())

        let markdown = try String(
            contentsOf: result.finalSession.noteURL,
            encoding: .utf8)
        let manifest = try RecordingManifestStore.load(
            from: result.finalSession.manifestURL)
        XCTAssertEqual(result.finalSession.basename, "2026-04-24-planning")
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("cleaned=true, processor=custom-command"))
        XCTAssertEqual(result.processorID, "custom-command")
        XCTAssertEqual(manifest.transcript?.processorID, "custom-command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.noteURL.path))
    }

    private func agentConfiguration(executable: URL) -> RecordingTranscriptionConfiguration {
        RecordingTranscriptionConfiguration(
            mlxWhisperPath: "/unused",
            whisperModel: "test/model",
            agentConfiguration: AgentConfiguration(
                provider: .customCommand,
                customExecutable: executable.path,
                customArguments: [],
                customPrompt: "",
                inheritEnvironment: false))
    }

    private func testTracks() -> RecordingTrackTranscriber {
        RecordingTrackTranscriber { _, _ in
            TranscriptionTracks(
                mic: [WhisperSegment(start: 0, end: 1, text: "Raw words")],
                system: [])
        }
    }

    private func makeValidAgent(at executable: URL) throws {
        let script = """
            #!/bin/sh
            /usr/bin/awk '
                BEGIN { print "<!-- topic: planning -->" }
                {
                    print
                    if ($0 == "---") {
                        frontmatterMarkers++
                        if (frontmatterMarkers == 2) {
                            print ""
                            print "## Summary"
                            print ""
                            print "Raw words."
                        }
                    }
                }
            '
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path)
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meetscribe-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        return url
    }

    private enum TestError: Error, LocalizedError {
        case renameFailed

        var errorDescription: String? {
            "rename failed"
        }
    }
}
