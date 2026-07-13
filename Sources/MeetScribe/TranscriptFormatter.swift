import Foundation

struct WhisperSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

enum Speaker: String { case me = "Me", them = "Them" }

struct TranscriptHeader {
    let date: String
    let app: String
    let duration: String
    let model: String
    let cleanedByClaude: Bool
}

enum TranscriptFormatter {
    static let pauseGap: Double = 2.0

    static func format(mic: [WhisperSegment], system: [WhisperSegment], header: TranscriptHeader) -> String {
        struct Tagged { let speaker: Speaker; let seg: WhisperSegment }
        let all = (mic.map { Tagged(speaker: .me, seg: $0) } + system.map { Tagged(speaker: .them, seg: $0) })
            .sorted { $0.seg.start < $1.seg.start }

        var turns: [(speaker: Speaker, start: Double, texts: [String])] = []
        var prevEnd: Double = -.infinity
        var prevSpeaker: Speaker? = nil
        for t in all {
            let text = t.seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if prevSpeaker == t.speaker, t.seg.start - prevEnd < pauseGap, !turns.isEmpty {
                turns[turns.count - 1].texts.append(text)
            } else {
                turns.append((t.speaker, t.seg.start, [text]))
            }
            prevEnd = t.seg.end
            prevSpeaker = t.speaker
        }

        var out = """
        # Meeting transcript  -  \(header.date)

        - App: \(header.app)
        - Duration: \(header.duration)
        - Model: \(header.model)
        - Cleanup: \(header.cleanedByClaude ? "cleaned by Claude" : "not cleaned (raw whisper)")

        ---

        """
        for turn in turns {
            out += "\n[\(hms(turn.start))] **\(turn.speaker.rawValue):** \(turn.texts.joined(separator: " "))\n"
        }
        return out
    }

    static func hms(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
