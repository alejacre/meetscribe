import Foundation

struct Transcriber {
    let mlxWhisperPath: String
    let model: String

    /// Transcribes one audio file; returns its segments.
    /// mlx_whisper writes <output-dir>/<input-basename>.json
    func transcribe(_ audio: URL) throws -> [WhisperSegment] {
        let dir = audio.deletingLastPathComponent()
        try Subprocess.run(mlxWhisperPath, [
            audio.path,
            "--model", model,
            "--output-format", "json",
            "--output-dir", dir.path,
        ])
        let jsonURL = dir.appendingPathComponent(audio.deletingPathExtension().lastPathComponent + ".json")
        let data = try Data(contentsOf: jsonURL)
        return try Self.parseSegments(data)
    }

    static func parseSegments(_ data: Data) throws -> [WhisperSegment] {
        struct Root: Codable { let segments: [WhisperSegment] }
        return try JSONDecoder().decode(Root.self, from: data).segments
    }
}
