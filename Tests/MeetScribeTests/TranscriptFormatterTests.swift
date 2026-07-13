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
                                            header: .init(date: "2026-07-13 15:30", app: "zoom",
                                                          duration: "45:02", model: "turbo", cleanedByClaude: false))
        XCTAssertTrue(md.contains("# Meeting transcript  -  2026-07-13 15:30"))
        XCTAssertTrue(md.contains("zoom"))
        XCTAssertTrue(md.contains("45:02"))
        XCTAssertTrue(md.contains("turbo"))
        XCTAssertTrue(md.contains("not cleaned"))
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

    func testEmptySegmentsSkipped() {
        let mic = [seg(0, 1, "   "), seg(2, 3, "real")]
        let md = TranscriptFormatter.format(mic: mic, system: [],
                                            header: .init(date: "d", app: "a", duration: "x", model: "m", cleanedByClaude: false))
        XCTAssertFalse(md.contains("[00:00:00]"))
        XCTAssertTrue(md.contains("**Me:** real"))
    }
}
