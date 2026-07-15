import XCTest
@testable import MeetScribe

final class SilentWavTests: XCTestCase {
    func testHeaderMagicsAndSizes() {
        let d = SilentWav.data(seconds: 1, sampleRate: 16000)
        // 44-byte header + 1s * 16000 * 2 bytes of silence.
        let dataBytes = 16000 * 2
        XCTAssertEqual(d.count, 44 + dataBytes)

        func ascii(_ range: Range<Int>) -> String { String(decoding: d[range], as: UTF8.self) }
        XCTAssertEqual(ascii(0..<4), "RIFF")
        XCTAssertEqual(ascii(8..<12), "WAVE")
        XCTAssertEqual(ascii(12..<16), "fmt ")
        XCTAssertEqual(ascii(36..<40), "data")

        func u32(_ off: Int) -> UInt32 {
            d[off..<off+4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        XCTAssertEqual(u32(4), UInt32(36 + dataBytes))  // RIFF chunk size
        XCTAssertEqual(u32(16), 16)                     // PCM fmt chunk
        XCTAssertEqual(u32(24), 16000)                  // sample rate
        XCTAssertEqual(u32(40), UInt32(dataBytes))      // data size
    }

    func testAllSamplesAreSilence() {
        let d = SilentWav.data(seconds: 1, sampleRate: 8000)
        XCTAssertTrue(d[44...].allSatisfy { $0 == 0 })
    }
}
