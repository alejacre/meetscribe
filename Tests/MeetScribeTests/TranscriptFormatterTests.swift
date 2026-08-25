import XCTest
@testable import MeetScribe

final class TranscriptFormatterTests: XCTestCase {
    func seg(_ start: Double, _ end: Double, _ text: String) -> WhisperSegment {
        WhisperSegment(start: start, end: end, text: text)
    }

    func testInterleavesByTimestampAndLabels() {
        let mic = [seg(5, 8, "Hola, ¿me oís?")]
        let system = [seg(0, 4, "Hi everyone."), seg(9, 12, "Yes, loud and clear.")]
        let md = TranscriptFormatter.format(mic: mic, system: system,
                                            header: .init(date: "2026-07-13 15:30", app: "zoom",
                                                          duration: "00:12", model: "turbo", cleanedByClaude: false))
        let lines = md.split(separator: "\n").map(String.init)
        let themFirst = lines.firstIndex { $0.contains("**Them:** Hi everyone.") }!
        let me = lines.firstIndex { $0.contains("**Me:** Hola, ¿me oís?") }!
        let themLast = lines.firstIndex { $0.contains("**Them:** Yes, loud and clear.") }!
        XCTAssertLessThan(themFirst, me)
        XCTAssertLessThan(me, themLast)
    }

    func testTimestampFormat() {
        let md = TranscriptFormatter.format(mic: [seg(3661, 3663, "one hour in")], system: [],
                                            header: .init(date: "d", app: "a", duration: "x", model: "m", cleanedByClaude: false))
        XCTAssertTrue(md.contains("[01:01:01] **Me:** one hour in"))
    }

    func testConsecutiveSameSpeakerSegmentsMergeWithinPause() {
        let mic = [seg(0, 2, "First part."), seg(2.5, 4, "same thought."), seg(10, 11, "New thought.")]
        let md = TranscriptFormatter.format(mic: mic, system: [],
                                            header: .init(date: "d", app: "a", duration: "x", model: "m", cleanedByClaude: false))
        XCTAssertTrue(md.contains("**Me:** First part. same thought."))
        XCTAssertTrue(md.contains("[00:00:10] **Me:** New thought."))
    }

    func testHeader() {
        let md = TranscriptFormatter.format(mic: [], system: [],
                                            header: .init(date: "2026-07-13", app: "zoom",
                                                          duration: "45:02", model: "turbo", cleanedByClaude: false))
        // YAML frontmatter matching the vault's meeting-note convention.
        XCTAssertTrue(md.hasPrefix("---\ndate: 2026-07-13\n"))
        XCTAssertTrue(md.contains("tags: [meeting, transcript]"))
        XCTAssertTrue(md.contains("attendees: []"))
        XCTAssertTrue(md.contains("## Transcript"))
        // Recording provenance lives in the trailing meta comment, not the frontmatter.
        XCTAssertTrue(md.contains(
            "<!-- meetscribe: app=zoom, duration=45:02, model=turbo, cleaned=false, processor=none -->"))
    }

    func testEchoSuppressionDropsMicDuplicatesOfSystem() {
        // Speaker echo: the mic picks up what the speakers play. Same words, same time.
        let system = [seg(10, 14, "We let people do it themselves.")]
        let mic = [seg(10.3, 14.2, "We let people do it themselves"),  // echo → drop
                   seg(20, 23, "Hola, esto lo digo yo.")]              // real → keep
        let filtered = TranscriptFormatter.suppressEcho(mic: mic, system: system)
        XCTAssertEqual(filtered, [mic[1]])
    }

    func testEchoSuppressionKeepsPartialOverlapDifferentText() {
        // Simultaneous speech: time overlaps but words differ → keep both.
        let system = [seg(10, 14, "and the quarterly numbers look fine")]
        let mic = [seg(11, 13, "perdona, ¿puedes repetir eso?")]
        let filtered = TranscriptFormatter.suppressEcho(mic: mic, system: system)
        XCTAssertEqual(filtered, mic)
    }

    func testEchoSuppressionHandlesFragmentedEcho() {
        // Whisper often splits the echo differently: a mic fragment contained in a
        // longer system segment still counts as echo.
        let system = [seg(0, 8, "I think we all got involved with the task force because we wanted to be builders")]
        let mic = [seg(2.1, 5.0, "we all got involved with the task force")]
        let filtered = TranscriptFormatter.suppressEcho(mic: mic, system: system)
        XCTAssertEqual(filtered, [])
    }

    func testEchoSuppressionIgnoresPunctuationAndCase() {
        let system = [seg(0, 3, " Fair question. ")]
        let mic = [seg(0.2, 3.1, "fair question")]
        let filtered = TranscriptFormatter.suppressEcho(mic: mic, system: system)
        XCTAssertEqual(filtered, [])
    }

    func testEchoSuppressionHandlesSmallRecognitionDifferences() {
        let system = [seg(0, 5, "That's why we're saying we had to take two planes")]
        let mic = [seg(0.2, 4.8, "we had to take two planes, five")]
        let filtered = TranscriptFormatter.suppressEcho(mic: mic, system: system)
        XCTAssertEqual(filtered, [])
    }

    func testEchoSuppressionKeepsWeakLexicalOverlap() {
        let system = [seg(0, 5, "We need to review the quarterly business results")]
        let mic = [seg(0.2, 4.8, "Can we review this another day instead?")]
        let filtered = TranscriptFormatter.suppressEcho(mic: mic, system: system)
        XCTAssertEqual(filtered, mic)
    }

    func testMarkProcessedPatchesHeaderLine() {
        let md = TranscriptFormatter.format(mic: [], system: [],
                                            header: .init(date: "d", app: "a", duration: "x", model: "m", cleanedByClaude: false))
        let patched = TranscriptFormatter.markProcessed(md, by: "claude-code")
        XCTAssertTrue(patched.contains("cleaned=true, processor=claude-code -->"))
        XCTAssertFalse(patched.contains("cleaned=false"))
    }

    func testExtractSummary() {
        let md = """
        ---
        date: 2026-07-13
        tags: [meeting, transcript]
        ---

        ## Summary
        We discussed the Q3 budget.
        Decision: ship in August.

        ## Transcript
        [00:00:01] **Me:** hi
        """
        XCTAssertEqual(TranscriptFormatter.extractSummary(md),
                       "We discussed the Q3 budget.\nDecision: ship in August.")
    }

    func testExtractSummaryMissingReturnsNil() {
        XCTAssertNil(TranscriptFormatter.extractSummary("---\ndate: d\n---\n\n## Transcript\nno summary here"))
    }

    func testDropsRepeatedFillerLoop() {
        // The observed bug: mic track collapsed to "Yes." repeated for the whole meeting.
        let mic = (0..<10).map { seg(Double($0 * 2), Double($0 * 2 + 1), "Yes.") }
            + [seg(30, 33, "is there anything we can do")]
        let filtered = TranscriptFormatter.dropHallucinations(mic)
        XCTAssertEqual(filtered.filter { $0.text == "Yes." }.count, 1)
        XCTAssertTrue(filtered.contains(seg(30, 33, "is there anything we can do")))
    }

    func testDropsFillerOnLongSilentSegment() {
        // "Thank you." stretched over a dead 30s block is a silence hallucination.
        let mic = [seg(0, 30, "Thank you."), seg(31, 33, "okay sounds good to me")]
        let filtered = TranscriptFormatter.dropHallucinations(mic)
        XCTAssertEqual(filtered, [seg(31, 33, "okay sounds good to me")])
    }

    func testKeepsShortRealFiller() {
        // A genuine quick "Yes." over 1s is real speech, not a hallucination.
        let mic = [seg(0, 1, "Yes."), seg(5, 8, "let us proceed then")]
        let filtered = TranscriptFormatter.dropHallucinations(mic)
        XCTAssertEqual(filtered, mic)
    }

    func testEmptySegmentsSkipped() {
        let mic = [seg(0, 1, "   "), seg(2, 3, "real")]
        let md = TranscriptFormatter.format(mic: mic, system: [],
                                            header: .init(date: "d", app: "a", duration: "x", model: "m", cleanedByClaude: false))
        XCTAssertFalse(md.contains("[00:00:00]"))
        XCTAssertTrue(md.contains("**Me:** real"))
    }
}
