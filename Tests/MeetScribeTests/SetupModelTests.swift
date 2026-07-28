import XCTest
@testable import MeetScribe

final class SetupModelTests: XCTestCase {
    func testModelCachePathMapping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = "mlx-community/whisper-large-v3-turbo"
        XCTAssertFalse(SetupModel.modelCached(repo, cacheRoot: root))

        let model = try XCTUnwrap(WhisperModels.model(id: repo))
        let dir = WhisperModels.snapshotURL(for: model, cacheRoot: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: dir.appendingPathComponent("weights.safetensors"))
        XCTAssertTrue(SetupModel.modelCached(repo, cacheRoot: root))
    }

    func testProgressPercent() {
        XCTAssertEqual(SetupModel.progressPercent(in: " 47%|████     | 1.2G/2.5G"), 47)
        XCTAssertNil(SetupModel.progressPercent(in: "downloading shards"))
        XCTAssertEqual(SetupModel.progressPercent(in: "10% ... 55% ... 100%"), 100)
        XCTAssertNil(SetupModel.progressPercent(in: "512% garbage"))  // out of range ignored
    }

    func testPinnedEngineVersionParsing() {
        XCTAssertTrue(SetupModel.isPinnedEngineList("""
        other-tool v1.0
        mlx-whisper v0.4.3
        - mlx_whisper
        """))
        XCTAssertFalse(SetupModel.isPinnedEngineList("mlx-whisper v0.5.0"))
    }

    func testAppendLogCarriageReturnRewritesLastLine() {
        var log = ""
        log = SetupModel.appendLog(log, chunk: "line one\n")
        log = SetupModel.appendLog(log, chunk: "10%")
        log = SetupModel.appendLog(log, chunk: "\r50%")
        log = SetupModel.appendLog(log, chunk: "\r100%")
        XCTAssertEqual(log, "line one\n100%")
    }

    func testAppendLogCarriageReturnAtStartClearsWhenNoNewline() {
        let log = SetupModel.appendLog("abc", chunk: "\rxy")
        XCTAssertEqual(log, "xy")
    }
}
