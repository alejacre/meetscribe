import XCTest
@testable import MeetScribe

final class SetupModelTests: XCTestCase {
    func testModelCachePathMapping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-\(UUID().uuidString)", isDirectory: true)
        let repo = "mlx-community/whisper-large-v3-turbo"
        XCTAssertFalse(SetupModel.modelCached(repo, cacheRoot: root))

        let dir = root.appendingPathComponent("models--mlx-community--whisper-large-v3-turbo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(SetupModel.modelCached(repo, cacheRoot: root))
    }

    func testProgressPercent() {
        XCTAssertEqual(SetupModel.progressPercent(in: " 47%|████     | 1.2G/2.5G"), 47)
        XCTAssertNil(SetupModel.progressPercent(in: "downloading shards"))
        XCTAssertEqual(SetupModel.progressPercent(in: "10% ... 55% ... 100%"), 100)
        XCTAssertNil(SetupModel.progressPercent(in: "512% garbage"))  // out of range ignored
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
