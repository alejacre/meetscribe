import Foundation
import ScreenCaptureKit
import AVFoundation

protocol AudioRecording: AnyObject, Sendable {
    var sourceWarning: String? { get }
    var onStreamDied: ((Error) -> Void)? { get set }
    func start(session: RecordingSession, targetBundleID: String?) async throws
    func stop() async throws
}

final class AudioRecorder: NSObject, AudioRecording, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var session: RecordingSession?
    private let queue = DispatchQueue(label: "meetscribe.audio")
    private let stateLock = NSLock()
    private var sourceWarningValue: String?
    var sourceWarning: String? {
        stateLock.withLock { sourceWarningValue }
    }
    /// Fired when the capture stream dies out from under us (display sleep,
    /// permission revoked); audio written so far stays on disk.
    private var streamDiedHandler: ((Error) -> Void)?
    var onStreamDied: ((Error) -> Void)? {
        get { stateLock.withLock { streamDiedHandler } }
        set { stateLock.withLock { streamDiedHandler = newValue } }
    }

    func start(session: RecordingSession, targetBundleID: String? = nil) async throws {
        stateLock.withLock { sourceWarningValue = nil }
        try session.createFolder()
        self.session = session
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetScribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found (screen recording permission?)"])
        }
        let filter: SCContentFilter
        if let targetBundleID {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == targetBundleID }) else {
                throw NSError(
                    domain: "MeetScribe",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "The meeting app is no longer available as an audio source."])
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            // Manual recording is explicitly presented as all-system-audio capture.
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
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
        stateLock.withLock { self.stream = stream }
        do {
            try await stream.startCapture()
        } catch {
            stateLock.withLock { self.stream = nil }
            throw error
        }
    }

    func stop() async throws {
        let active = stateLock.withLock {
            let active = stream
            stream = nil
            return active
        }
        var stopError: Error?
        do { try await active?.stopCapture() }
        catch { stopError = error }
        queue.sync { micFile = nil; systemFile = nil } // flush/close
        if let session {
            try session.secureFile(session.micURL)
            try session.secureFile(session.systemURL)
        }
        if let stopError { throw stopError }
    }

    // MARK: SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let callback = stateLock.withLock {
            guard self.stream != nil else { return nil as ((Error) -> Void)? }
            self.stream = nil
            return streamDiedHandler
        }
        callback?(error)
    }

    // MARK: SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone,
              sampleBuffer.isValid,
              let session,
              let pcm = sampleBuffer.asPCMBuffer else { return }
        do {
            switch type {
            case .microphone: try append(pcm, to: &micFile, url: session.micURL)
            case .audio: try append(pcm, to: &systemFile, url: session.systemURL)
            default: break
            }
        } catch {
            stateLock.withLock {
                sourceWarningValue = "A capture source failed: \(error.localizedDescription)"
            }
        }
    }

    private func append(_ pcm: AVAudioPCMBuffer, to file: inout AVAudioFile?, url: URL) throws {
        if file == nil { file = try makeFile(url: url, format: pcm.format) }
        try file?.write(from: pcm)
    }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path)
        return file
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
        // export(to:) fails with "Cannot Save" if the destination already exists (e.g. a
        // retry, or a reused asset dir); clear it first so the mix always writes cleanly.
        try? FileManager.default.removeItem(at: session.mixURL)
        try await export.export(to: session.mixURL, as: .m4a)
        try session.secureFile(session.mixURL)
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
