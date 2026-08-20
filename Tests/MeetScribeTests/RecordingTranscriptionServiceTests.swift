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
}
