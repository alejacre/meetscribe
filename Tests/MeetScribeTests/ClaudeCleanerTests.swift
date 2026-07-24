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
}
