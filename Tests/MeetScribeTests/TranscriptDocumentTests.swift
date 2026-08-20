import XCTest
@testable import MeetScribe

final class TranscriptDocumentTests: XCTestCase {
    func testParsesBrowserContentFromMeetScribeMarkdown() {
        let markdown = """
        ---
        date: 2026-08-20
        attendees: []
        tags: [meeting, transcript, product]
        ---

        ## Summary
        The team reviewed the desktop transcript browser.
        The local build is ready for validation.

        ## Decisions
        - Keep transcription local by default.
        - Replace promotional mockups with real screenshots.

        ## Transcript
        [00:00:03] **Me:** Let's review the release plan.
        [00:00:07] **Them:** The local build is green.

        <!-- meetscribe: app=zoom, duration=00:24:18, model=test, cleaned=true, processor=test -->
        """

        let document = TranscriptDocument.parse(
            markdown,
            filename: "2026-08-20-product-review")

        XCTAssertEqual(document.title, "2026-08-20-product-review")
        XCTAssertEqual(document.date, "2026-08-20")
        XCTAssertEqual(document.tags, ["meeting", "transcript", "product"])
        XCTAssertEqual(
            document.summary,
            "The team reviewed the desktop transcript browser.\n"
                + "The local build is ready for validation.")
        XCTAssertEqual(document.decisions, [
            "Keep transcription local by default.",
            "Replace promotional mockups with real screenshots.",
        ])
        XCTAssertEqual(document.turns, [
            TranscriptTurn(
                timestamp: "00:00:03",
                speaker: "Me",
                text: "Let's review the release plan."),
            TranscriptTurn(
                timestamp: "00:00:07",
                speaker: "Them",
                text: "The local build is green."),
        ])
        XCTAssertEqual(document.sourceApp, "zoom")
        XCTAssertEqual(document.duration, "00:24:18")
        XCTAssertNil(document.unstructuredTranscript)
    }

    func testSearchableTextIncludesTranscriptAndDecisions() {
        let document = TranscriptDocument.parse(
            """
            ## Decisions
            * Ship the recordings window.

            ## Transcript
            [00:00:02] **Them:** Search every local transcript.
            """,
            filename: "2026-08-20-release-planning")

        XCTAssertTrue(document.searchableText.contains("Ship the recordings window"))
        XCTAssertTrue(document.searchableText.contains("Search every local transcript"))
    }

    func testMissingOptionalSectionsProducesReadableDocument() {
        let document = TranscriptDocument.parse(
            "## Transcript\nA legacy transcript without timestamped turns.",
            filename: "manual")

        XCTAssertEqual(document.title, "manual")
        XCTAssertNil(document.summary)
        XCTAssertTrue(document.decisions.isEmpty)
        XCTAssertTrue(document.turns.isEmpty)
        XCTAssertEqual(
            document.unstructuredTranscript,
            "A legacy transcript without timestamped turns.")
        XCTAssertTrue(document.searchableText.contains("legacy transcript"))
    }

    func testDuplicateMetadataKeysUseLastValueWithoutCrashing() {
        let document = TranscriptDocument.parse(
            """
            ## Transcript
            Legacy transcript.

            <!-- meetscribe: app=zoom, app=teams, duration=00:01:00 -->
            """,
            filename: "duplicate-metadata")

        XCTAssertEqual(document.sourceApp, "teams")
        XCTAssertEqual(document.duration, "00:01:00")
    }

    func testWrappedTranscriptLinesArePreservedOnPreviousTurn() {
        let document = TranscriptDocument.parse(
            """
            ## Transcript
            [00:00:02] **Them:** The first line wraps
            onto a second line with searchable details.
            [00:00:05] **Me:** A new turn starts here.
            """,
            filename: "wrapped")

        XCTAssertEqual(document.turns.count, 2)
        XCTAssertEqual(
            document.turns[0].text,
            "The first line wraps\nonto a second line with searchable details.")
        XCTAssertTrue(document.searchableText.contains("searchable details"))
    }
}
