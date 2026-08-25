import XCTest

final class ReleaseScriptTests: XCTestCase {
    func testFinalArchiveIsCreatedAfterStapling() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repository.appendingPathComponent("scripts/release.sh"),
            encoding: .utf8)
        let lines = script.split(separator: "\n").map(String.init)
        let archiveCalls = lines.indices.filter { lines[$0] == "create_archive" }
        let submit = try XCTUnwrap(lines.firstIndex {
            $0.hasPrefix("xcrun notarytool submit ")
        })
        let staple = try XCTUnwrap(lines.firstIndex {
            $0.hasPrefix("xcrun stapler staple ")
        })
        let checksum = try XCTUnwrap(lines.firstIndex {
            $0.hasPrefix("shasum -a 256 ")
        })

        XCTAssertEqual(archiveCalls.count, 2)
        XCTAssertLessThan(archiveCalls[0], submit)
        XCTAssertLessThan(submit, staple)
        XCTAssertLessThan(staple, archiveCalls[1])
        XCTAssertLessThan(archiveCalls[1], checksum)
    }
}
