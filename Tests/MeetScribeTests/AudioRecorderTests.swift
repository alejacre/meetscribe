import XCTest
import AVFoundation
@testable import MeetScribe

final class AudioRecorderTests: XCTestCase {
    func testPreferredDisplayUsesBuiltInBeforeExternalMainDisplay() {
        let displayIDs: [CGDirectDisplayID] = [30, 10]

        let index = AudioRecorder.preferredDisplayIndex(
            displayIDs: displayIDs,
            mainDisplayID: 30,
            isBuiltIn: { $0 == 10 })

        XCTAssertEqual(index, 1)
    }

    func testPreferredDisplayFallsBackToMainThenFirstAvailable() {
        let displayIDs: [CGDirectDisplayID] = [30, 40]

        XCTAssertEqual(
            AudioRecorder.preferredDisplayIndex(
                displayIDs: displayIDs,
                mainDisplayID: 40,
                isBuiltIn: { _ in false }),
            1)
        XCTAssertEqual(
            AudioRecorder.preferredDisplayIndex(
                displayIDs: displayIDs,
                mainDisplayID: 50,
                isBuiltIn: { _ in false }),
            0)
        XCTAssertNil(
            AudioRecorder.preferredDisplayIndex(
                displayIDs: [],
                mainDisplayID: 50,
                isBuiltIn: { _ in false }))
    }

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

    func testMixCreatesPrivateAudioFromAvailableTrack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "meetscribe-audio-mix-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(
            root: root,
            start: Date(),
            appName: nil)
        try session.createFolder()
        try writeSilentM4A(to: session.micURL)

        try await AudioRecorder.mix(session: session)

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.mixURL.path))
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: session.mixURL.path)[.posixPermissions]
                as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    private func writeSilentM4A(to url: URL) throws {
        let sampleRate = 48_000.0
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1))
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate / 10)))
        buffer.frameLength = buffer.frameCapacity
        if let channel = buffer.floatChannelData?.pointee {
            channel.initialize(
                repeating: 0,
                count: Int(buffer.frameLength))
        }
        try file.write(from: buffer)
    }
}
