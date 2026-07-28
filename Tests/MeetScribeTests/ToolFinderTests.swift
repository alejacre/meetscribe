import XCTest
@testable import MeetScribe

final class ToolFinderTests: XCTestCase {
    func testRejectsShellMetacharacters() {
        XCTAssertNil(ToolFinder.findTool("claude; touch /tmp/injected"))
        XCTAssertNil(ToolFinder.findTool(""))
    }
}
