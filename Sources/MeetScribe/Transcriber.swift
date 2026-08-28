import Foundation
import AVFoundation
import Accelerate

struct TranscriptionTracks: Sendable {
    let mic: [WhisperSegment]
    let system: [WhisperSegment]
}

struct Transcriber {
    struct DetectedTranscript: Equatable, Sendable {
        let segments: [WhisperSegment]
        let language: String?
    }

    static let allowedLanguages: Set<String> = ["en", "es"]
    static let fallbackLanguage = "en"
    static let audibleTrackRMSThreshold: Float = 0.001

    let mlxWhisperPath: String
    let model: String
    private let modelResolver: @Sendable (String) -> String?

    init(mlxWhisperPath: String, model: String,
         modelResolver: @escaping @Sendable (String) -> String? = WhisperModels.resolvedPath) {
        self.mlxWhisperPath = mlxWhisperPath
        self.model = model
        self.modelResolver = modelResolver
    }

    /// Transcribes each audio file in its OWN mlx_whisper invocation, forcing a distinct
    /// --output-name per file. Do NOT batch multiple files into one invocation: mlx_whisper
    /// 0.4.3 overwrites the first file's JSON with the last file's output (verified),
    /// which silently destroys the per-track Me/Them attribution.
    func transcribe(mic: URL, system: URL) throws -> TranscriptionTracks {
        var micResult = try transcribe(mic, language: nil)
        var systemResult = try transcribe(system, language: nil)

        let micLanguage = Self.allowedLanguage(micResult)
        let systemLanguage = Self.allowedLanguage(systemResult)

        if Self.needsLanguageRetry(micResult), let reference = systemLanguage {
            micResult = try transcribe(mic, language: reference)
        }
        if Self.needsLanguageRetry(systemResult), let reference = micLanguage {
            systemResult = try transcribe(system, language: reference)
        }

        if Self.needsLanguageRetry(micResult) {
            micResult = try transcribe(mic, language: Self.fallbackLanguage)
        }
        if Self.needsLanguageRetry(systemResult) {
            systemResult = try transcribe(system, language: Self.fallbackLanguage)
        }

        return TranscriptionTracks(
            mic: micResult.segments,
            system: systemResult.segments)
    }

    private func transcribe(
        _ audio: URL,
        language: String?
    ) throws -> DetectedTranscript {
        guard FileManager.default.fileExists(atPath: audio.path) else {
            return DetectedTranscript(segments: [], language: nil)
        }
        guard Self.containsAudibleAudio(audio) else {
            return DetectedTranscript(segments: [], language: nil)
        }
        guard let modelPath = modelResolver(model) else {
            throw TranscriberError.modelNotCached(model)
        }
        let dir = audio.deletingLastPathComponent()
        let name = audio.deletingPathExtension().lastPathComponent
        var arguments = [
            audio.path,
            "--model", modelPath,
            "--output-format", "json",
            "--output-dir", dir.path,
            "--output-name", name,
        ] + Self.antiHallucinationArgs
        if let language {
            arguments += ["--language", language]
        }
        try Subprocess.run(mlxWhisperPath, arguments)
        let jsonURL = dir.appendingPathComponent(name + ".json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        return try Self.parseTranscript(Data(contentsOf: jsonURL))
    }

    /// Avoids an mlx-whisper 0.4.3 pathological case where a long, all-silent
    /// track can keep Metal saturated without producing output. If AVFoundation
    /// cannot inspect the file, preserve the existing behavior and let Whisper
    /// report the input error.
    static func containsAudibleAudio(_ audio: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: audio),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: 16_384)
        else {
            return true
        }

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                return true
            }
            guard buffer.frameLength > 0 else { break }
            if Self.isAudibleForTranscription(buffer) {
                return true
            }
        }
        return false
    }

    private static func isAudibleForTranscription(
        _ buffer: AVAudioPCMBuffer
    ) -> Bool {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData
        else {
            return true
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleCount = buffer.format.isInterleaved
            ? frameCount * channelCount
            : frameCount
        let bufferCount = buffer.format.isInterleaved ? 1 : channelCount
        guard sampleCount > 0, bufferCount > 0 else { return false }

        for channel in 0..<bufferCount {
            var rms: Float = 0
            vDSP_rmsqv(
                channels[channel],
                1,
                &rms,
                vDSP_Length(sampleCount))
            if rms >= audibleTrackRMSThreshold {
                return true
            }
        }
        return false
    }

    /// Decoder flags that stop Whisper from hallucinating on quiet tracks. The mic track
    /// is mostly the user listening in silence; with mlx_whisper's default
    /// `condition_on_previous_text=True`, one stray "Yes." feeds back into the decoder and
    /// loops for the whole meeting (observed: 1893× "Yes." over 33 min). Disabling that
    /// conditioning breaks the loop; the silence/hallucination thresholds drop the rest.
    /// Residual single-shot fillers ("Thank you." on a dead 30s block) are cleaned by
    /// TranscriptFormatter.dropHallucinations, since Whisper's own no_speech gate misses them.
    static let antiHallucinationArgs = [
        "--condition-on-previous-text", "False",
        "--word-timestamps", "True",
        "--hallucination-silence-threshold", "2",
        "--compression-ratio-threshold", "2.0",
        "--logprob-threshold", "-1.0",
        "--no-speech-threshold", "0.6",
    ]

    static func parseTranscript(_ data: Data) throws -> DetectedTranscript {
        struct Root: Codable {
            let language: String?
            let segments: [WhisperSegment]
        }
        let root = try JSONDecoder().decode(Root.self, from: data)
        return DetectedTranscript(
            segments: root.segments,
            language: normalizedLanguage(root.language))
    }

    private static func needsLanguageRetry(
        _ transcript: DetectedTranscript
    ) -> Bool {
        !transcript.segments.isEmpty && allowedLanguage(transcript) == nil
    }

    private static func allowedLanguage(
        _ transcript: DetectedTranscript
    ) -> String? {
        guard !transcript.segments.isEmpty,
              let language = normalizedLanguage(transcript.language),
              allowedLanguages.contains(language)
        else {
            return nil
        }
        return language
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        switch language.lowercased() {
        case "en", "english":
            return "en"
        case "es", "spanish", "castilian":
            return "es"
        default:
            return language.lowercased()
        }
    }

    enum TranscriberError: Error, LocalizedError {
        case modelNotCached(String)

        var errorDescription: String? {
            switch self {
            case .modelNotCached(let model):
                "The locked model \(model) is not fully downloaded. Run Setup Assistant."
            }
        }
    }
}
