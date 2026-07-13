import Foundation

struct Transcriber {
    let mlxWhisperPath: String
    let model: String

    /// Transcribes several audio files in ONE mlx_whisper invocation (the CLI accepts
    /// multiple positional files), so the model is loaded once instead of per-file.
    /// mlx_whisper writes <output-dir>/<input-basename>.json for each input.
    /// Returns segments per input, in the same order; missing files yield [].
    func transcribe(_ audios: [URL]) throws -> [[WhisperSegment]] {
        let existing = audios.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            let dir = existing[0].deletingLastPathComponent()
            try Subprocess.run(mlxWhisperPath, existing.map(\.path) + [
                "--model", model,
                "--output-format", "json",
                "--output-dir", dir.path,
            ])
        }
        return try audios.map { audio in
            let jsonURL = audio.deletingLastPathComponent()
                .appendingPathComponent(audio.deletingPathExtension().lastPathComponent + ".json")
            guard FileManager.default.fileExists(atPath: jsonURL.path) else { return [] }
            defer { try? FileManager.default.removeItem(at: jsonURL) }
            return try Self.parseSegments(Data(contentsOf: jsonURL))
        }
    }

    static func parseSegments(_ data: Data) throws -> [WhisperSegment] {
        struct Root: Codable { let segments: [WhisperSegment] }
        return try JSONDecoder().decode(Root.self, from: data).segments
    }
}
