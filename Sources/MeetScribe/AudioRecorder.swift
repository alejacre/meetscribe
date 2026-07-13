import Foundation
import ScreenCaptureKit
import AVFoundation

final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var session: RecordingSession?
    private let queue = DispatchQueue(label: "meetscribe.audio")
    private(set) var sourceWarning: String?

    func start(session: RecordingSession) async throws {
        try session.createFolder()
        self.session = session
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetScribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found (screen recording permission?)"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // SCK requires a video stream; keep it tiny and never write it
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
        queue.sync { micFile = nil; systemFile = nil } // flush/close
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone,
              sampleBuffer.isValid,
              let session,
              let pcm = sampleBuffer.asPCMBuffer else { return }
        do {
            switch type {
            case .microphone:
                if micFile == nil { micFile = try makeFile(url: session.micURL, format: pcm.format) }
                try micFile?.write(from: pcm)
            case .audio:
                if systemFile == nil { systemFile = try makeFile(url: session.systemURL, format: pcm.format) }
                try systemFile?.write(from: pcm)
            default: break
            }
        } catch {
            sourceWarning = "A capture source failed: \(error.localizedDescription)"
        }
    }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Offline mix mic + system into audio.m4a after stop.
    static func mix(session: RecordingSession) async throws {
        let comp = AVMutableComposition()
        for url in [session.micURL, session.systemURL]
        where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let srcTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let dstTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duration = try await asset.load(.duration)
            try dstTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: srcTrack, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A)
        else { throw NSError(domain: "MeetScribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"]) }
        try await export.export(to: session.mixURL, as: .m4a)
    }
}

extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? withAudioBufferList { list, _ -> AVAudioPCMBuffer? in
            guard let absd = formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate,
                                             channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer)
        } ?? nil
    }
}
