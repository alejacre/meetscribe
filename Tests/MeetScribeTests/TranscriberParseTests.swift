import XCTest
@testable import MeetScribe

final class TranscriberParseTests: XCTestCase {
    func testParsesWhisperJSON() throws {
        let json = """
        {"text": " Hola. Adiós.", "language": "es",
         "segments": [
           {"id": 0, "start": 0.0, "end": 1.5, "text": " Hola.", "tokens": [1], "temperature": 0.0},
           {"id": 1, "start": 2.0, "end": 3.0, "text": " Adiós.", "tokens": [2], "temperature": 0.0}
         ]}
        """.data(using: .utf8)!
        let segs = try Transcriber.parseSegments(json)
        XCTAssertEqual(segs, [WhisperSegment(start: 0.0, end: 1.5, text: " Hola."),
                              WhisperSegment(start: 2.0, end: 3.0, text: " Adiós.")])
        let transcript = try Transcriber.parseTranscript(json)
        XCTAssertEqual(transcript.language, "es")
        XCTAssertEqual(transcript.segments, segs)
    }

    func testNormalizesSupportedLanguageNames() throws {
        let json = """
        {"language": "English",
         "segments": [{"start": 0.0, "end": 1.0, "text": " Hello."}]}
        """.data(using: .utf8)!

        XCTAssertEqual(try Transcriber.parseTranscript(json).language, "en")
    }
}
