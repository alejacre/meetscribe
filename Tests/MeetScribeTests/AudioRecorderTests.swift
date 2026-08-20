import XCTest
@testable import MeetScribe

final class AudioRecorderTests: XCTestCase {
    func testIdleRecorderStoresCallbackAndStopsIdempotently() async throws {
        let recorder = AudioRecorder()
        recorder.onStreamDied = { _ in }

        XCTAssertNotNil(recorder.onStreamDied)
        XCTAssertNil(recorder.sourceWarning)

        try await recorder.stop()
        try await recorder.stop()

        recorder.onStreamDied = nil
        XCTAssertNil(recorder.onStreamDied)
    }
}
