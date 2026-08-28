import XCTest
@testable import MeetScribe

final class TranscriptTopicSuggesterTests: XCTestCase {
    func testRepeatedPhraseBecomesTopic() {
        XCTAssertEqual(
            TranscriptTopicSuggester.slug(
                "We reviewed the fee cycle. The fee cycle needs validation."),
            "fee-cycle")
    }

    func testStopwordsAndNumbersDoNotBecomeTopic() {
        XCTAssertEqual(
            TranscriptTopicSuggester.slug(
                "Okay, we should review the 2026 rate card and rate card changes."),
            "rate-card")
    }

    func testEmptyOrFillerOnlyTextHasNoTopic() {
        XCTAssertNil(TranscriptTopicSuggester.slug("okay yeah thank you"))
    }
}
