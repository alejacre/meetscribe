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
            ])
            let jsonURL = dir.appendingPathComponent(name + ".json")
            defer { try? FileManager.default.removeItem(at: jsonURL) }
            return try Self.parseSegments(Data(contentsOf: jsonURL))
        }
    }

    static func parseSegments(_ data: Data) throws -> [WhisperSegment] {
        struct Root: Codable { let segments: [WhisperSegment] }
        return try JSONDecoder().decode(Root.self, from: data).segments
    }
}
