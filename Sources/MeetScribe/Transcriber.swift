import Foundation

struct Transcriber {
    let mlxWhisperPath: String
    let model: String

    /// Transcribes each audio file in its OWN mlx_whisper invocation, forcing a distinct
    /// --output-name per file. Do NOT batch multiple files into one invocation: mlx_whisper
    /// 0.4.3 overwrites the first file's JSON with the last file's output (verified),
    /// which silently destroys the per-track Me/Them attribution.
    /// Returns segments per input, in the same order; missing files yield [].
    func transcribe(_ audios: [URL]) throws -> [[WhisperSegment]] {
        try audios.map { audio in
            guard FileManager.default.fileExists(atPath: audio.path) else { return [] }
            let dir = audio.deletingLastPathComponent()
            let name = audio.deletingPathExtension().lastPathComponent
            try Subprocess.run(mlxWhisperPath, [
                audio.path,
                "--model", model,
                "--output-format", "json",
                "--output-dir", dir.path,
                "--output-name", name,
            ] + Self.antiHallucinationArgs)
            let jsonURL = dir.appendingPathComponent(name + ".json")
            defer { try? FileManager.default.removeItem(at: jsonURL) }
            return try Self.parseSegments(Data(contentsOf: jsonURL))
        }
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
        "--hallucination-silence-threshold", "2",
        "--compression-ratio-threshold", "2.0",
        "--logprob-threshold", "-1.0",
        "--no-speech-threshold", "0.6",
    ]

    static func parseSegments(_ data: Data) throws -> [WhisperSegment] {
        struct Root: Codable { let segments: [WhisperSegment] }
        return try JSONDecoder().decode(Root.self, from: data).segments
    }
}
