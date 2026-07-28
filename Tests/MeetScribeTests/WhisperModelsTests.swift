import XCTest
@testable import MeetScribe

final class WhisperModelsTests: XCTestCase {
    func testPublishedRevisionParsing() {
        let data = Data(#"{"sha":"abc123","id":"model"}"#.utf8)
        XCTAssertEqual(WhisperModels.publishedRevision(in: data), "abc123")
    }

    func testUnknownModelIsNotAcceptedAsCached() {
        XCTAssertFalse(WhisperModels.isCached("untrusted/arbitrary-model"))
    }

    func testLockedModelsHaveFullCommitRevisions() {
        XCTAssertTrue(WhisperModels.all.allSatisfy {
            $0.revision.count == 40 && $0.revision.allSatisfy { $0.isHexDigit }
        })
    }

    func testPartialSnapshotIsNotConsideredCached() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetscribe-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try XCTUnwrap(WhisperModels.all.first)
        let snapshot = WhisperModels.snapshotURL(for: model, cacheRoot: root)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))

        XCTAssertFalse(WhisperModels.isCached(model.id, cacheRoot: root))
    }
}
