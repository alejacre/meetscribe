import XCTest
import AVFoundation
@testable import MeetScribe

final class TranscriberInvocationTests: XCTestCase {
    func testRunsEachTrackSeparatelyWithLockedArguments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-transcriber-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("calls.log")
        let executable = try makeFakeWhisper(root: root, log: log)
        let mic = root.appendingPathComponent("mic.m4a")
        let system = root.appendingPathComponent("system.m4a")
        try Data().write(to: mic)
        try Data().write(to: system)

        let tracks = try Transcriber(
            mlxWhisperPath: executable.path,
            model: "test/model",
            modelResolver: { _ in "locked-test-model" }).transcribe(mic: mic, system: system)

        XCTAssertEqual(tracks.mic.first?.text, "mic")
        XCTAssertEqual(tracks.system.first?.text, "system")
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(calls.components(separatedBy: "CALL:").count - 1, 2)
        XCTAssertTrue(calls.contains("CALL:\(mic.path)"))
        XCTAssertTrue(calls.contains("CALL:\(system.path)"))
        XCTAssertEqual(calls.components(separatedBy: "--condition-on-previous-text").count - 1, 2)
        XCTAssertEqual(calls.components(separatedBy: "--word-timestamps").count - 1, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mic.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("system.json").path))
    }

    func testRetriesUnsupportedMicLanguageUsingValidSystemLanguage() throws {
        let root = try temporaryDirectory("language-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("calls.log")
        let executable = try makeFakeWhisper(
            root: root,
            log: log,
            detectedLanguages: ["mic": "ru", "system": "en"])
        let mic = root.appendingPathComponent("mic.m4a")
        let system = root.appendingPathComponent("system.m4a")
        try Data().write(to: mic)
        try Data().write(to: system)

        let tracks = try Transcriber(
            mlxWhisperPath: executable.path,
            model: "test/model",
            modelResolver: { _ in "locked-test-model" })
            .transcribe(mic: mic, system: system)

        XCTAssertEqual(tracks.mic.first?.text, "mic-en")
        XCTAssertEqual(tracks.system.first?.text, "system")
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(calls.components(separatedBy: "CALL:").count - 1, 3)
        XCTAssertEqual(calls.components(separatedBy: "--language\nen").count - 1, 1)
    }

    func testKeepsDifferentAllowedLanguagesWithoutRetry() throws {
        let root = try temporaryDirectory("bilingual")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("calls.log")
        let executable = try makeFakeWhisper(
            root: root,
            log: log,
            detectedLanguages: ["mic": "es", "system": "en"])
        let mic = root.appendingPathComponent("mic.m4a")
        let system = root.appendingPathComponent("system.m4a")
        try Data().write(to: mic)
        try Data().write(to: system)

        let tracks = try Transcriber(
            mlxWhisperPath: executable.path,
            model: "test/model",
            modelResolver: { _ in "locked-test-model" })
            .transcribe(mic: mic, system: system)

        XCTAssertEqual(tracks.mic.first?.text, "mic")
        XCTAssertEqual(tracks.system.first?.text, "system")
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(calls.components(separatedBy: "CALL:").count - 1, 2)
        XCTAssertFalse(calls.contains("--language"))
    }

    func testFallsBackToEnglishWhenBothDetectedLanguagesAreUnsupported() throws {
        let root = try temporaryDirectory("language-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("calls.log")
        let executable = try makeFakeWhisper(
            root: root,
            log: log,
            detectedLanguages: ["mic": "ru", "system": "zh"])
        let mic = root.appendingPathComponent("mic.m4a")
        let system = root.appendingPathComponent("system.m4a")
        try Data().write(to: mic)
        try Data().write(to: system)

        let tracks = try Transcriber(
            mlxWhisperPath: executable.path,
            model: "test/model",
            modelResolver: { _ in "locked-test-model" })
            .transcribe(mic: mic, system: system)

        XCTAssertEqual(tracks.mic.first?.text, "mic-en")
        XCTAssertEqual(tracks.system.first?.text, "system-en")
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(calls.components(separatedBy: "CALL:").count - 1, 4)
        XCTAssertEqual(calls.components(separatedBy: "--language\nen").count - 1, 2)
    }

    func testMissingTrackReturnsEmptyWithoutInvocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-transcriber-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("calls.log")
        let executable = try makeFakeWhisper(root: root, log: log)
        let system = root.appendingPathComponent("system.m4a")
        try Data().write(to: system)

        let tracks = try Transcriber(
            mlxWhisperPath: executable.path,
            model: "test/model",
            modelResolver: { _ in "locked-test-model" }).transcribe(
                mic: root.appendingPathComponent("missing.m4a"),
                system: system)

        XCTAssertTrue(tracks.mic.isEmpty)
        XCTAssertEqual(tracks.system.first?.text, "system")
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(calls.components(separatedBy: "CALL:").count - 1, 1)
    }

    func testSilentTrackIsSkippedWhileAudibleTrackIsTranscribed() throws {
        let root = try temporaryDirectory("silent-track")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("calls.log")
        let executable = try makeFakeWhisper(root: root, log: log)
        let mic = root.appendingPathComponent("mic.m4a")
        let system = root.appendingPathComponent("system.m4a")
        try writeM4A(to: mic, amplitude: 0)
        try writeM4A(to: system, amplitude: 0.002)

        let tracks = try Transcriber(
            mlxWhisperPath: executable.path,
            model: "test/model",
            modelResolver: { _ in "locked-test-model" })
            .transcribe(mic: mic, system: system)

        XCTAssertTrue(tracks.mic.isEmpty)
        XCTAssertEqual(tracks.system.first?.text, "system")
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(calls.components(separatedBy: "CALL:").count - 1, 1)
        XCTAssertFalse(calls.contains("CALL:\(mic.path)"))
        XCTAssertTrue(calls.contains("CALL:\(system.path)"))
    }

    func testUnreadableExistingTrackStillUsesWhisperForDiagnostics() throws {
        let root = try temporaryDirectory("unreadable-track")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("broken.m4a")
        try Data("not audio".utf8).write(to: audio)

        XCTAssertTrue(Transcriber.containsAudibleAudio(audio))
    }

    func testRejectsAudioWhenLockedModelIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-transcriber-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("mic.m4a")
        try Data().write(to: audio)

        XCTAssertThrowsError(try Transcriber(
            mlxWhisperPath: "/missing",
            model: "test/model",
            modelResolver: { _ in nil }).transcribe(mic: audio, system: audio)) { error in
                guard case Transcriber.TranscriberError.modelNotCached("test/model") = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meetscribe-transcriber-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return root
    }

    private func makeFakeWhisper(
        root: URL,
        log: URL,
        detectedLanguages: [String: String] = [
            "mic": "en",
            "system": "en",
        ]
    ) throws -> URL {
        let executable = root.appendingPathComponent("fake-whisper")
        let micLanguage = detectedLanguages["mic"] ?? "en"
        let systemLanguage = detectedLanguages["system"] ?? "en"
        let script = """
        #!/bin/sh
        printf 'CALL:%s\\n' "$1" >> "\(log.path)"
        printf '%s\\n' "$@" >> "\(log.path)"
        input="$1"
        output_dir=""
        output_name=""
        language=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output-dir) shift; output_dir="$1" ;;
            --output-name) shift; output_name="$1" ;;
            --language) shift; language="$1" ;;
          esac
          shift
        done
        if [ -z "$language" ]; then
          if [ "$output_name" = "mic" ]; then language="\(micLanguage)"; else language="\(systemLanguage)"; fi
          text="$output_name"
        else
          text="$output_name-$language"
        fi
        printf '{"language":"%s","segments":[{"start":0,"end":1,"text":"%s"}]}' \
          "$language" "$text" > "$output_dir/$output_name.json"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path)
        return executable
    }

    private func writeM4A(to url: URL, amplitude: Float) throws {
        let sampleRate = 48_000.0
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1))
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate / 10)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        channel.initialize(
            repeating: amplitude,
            count: Int(buffer.frameLength))
        try file.write(from: buffer)
    }
}
