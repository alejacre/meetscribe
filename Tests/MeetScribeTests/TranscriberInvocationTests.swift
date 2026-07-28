import XCTest
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mic.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("system.json").path))
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

    private func makeFakeWhisper(root: URL, log: URL) throws -> URL {
        let executable = root.appendingPathComponent("fake-whisper")
        let script = """
        #!/bin/sh
        printf 'CALL:%s\\n' "$1" >> "\(log.path)"
        printf '%s\\n' "$@" >> "\(log.path)"
        input="$1"
        output_dir=""
        output_name=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output-dir) shift; output_dir="$1" ;;
            --output-name) shift; output_name="$1" ;;
          esac
          shift
        done
        printf '{"segments":[{"start":0,"end":1,"text":"%s"}]}' "$output_name" > "$output_dir/$output_name.json"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path)
        return executable
    }
}
