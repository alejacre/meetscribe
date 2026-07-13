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
    /// Echo tolerance: mic echo of speaker audio lags/leads the system track slightly.
    static let echoTimeSlack: Double = 1.5

    /// Removes mic segments that are acoustic echo of the system track (speakers
    /// picked up by the microphone when the user is not wearing headphones).
    /// A mic segment is echo when it overlaps a system segment in time (with slack)
    /// and its normalized text is contained in  -  or nearly identical to  -  that
    /// system segment's text. The system track is authoritative for remote speech.
    static func suppressEcho(mic: [WhisperSegment], system: [WhisperSegment]) -> [WhisperSegment] {
        guard !system.isEmpty else { return mic }
        return mic.filter { m in
            let mText = normalize(m.text)
            guard !mText.isEmpty else { return true }
            for s in system {
                guard m.start < s.end + echoTimeSlack, m.end > s.start - echoTimeSlack else { continue }
                let sText = normalize(s.text)
                if sText.contains(mText) || mText.contains(sText) { return false }
            }
            return true
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(separator: " ").joined(separator: " ")
    }

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

    /// Flips the header's Cleanup line after Claude cleanup (the prompt forbids
    /// Claude itself from editing the header).
    static func markCleaned(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "- Cleanup: not cleaned (raw whisper)",
                                      with: "- Cleanup: cleaned by Claude")
    }

    /// Extracts the body of the "## Summary" section (added by Claude cleanup),
    /// or nil if the transcript has none.
    static func extractSummary(_ markdown: String) -> String? {
        guard let range = markdown.range(of: "## Summary") else { return nil }
        let after = markdown[range.upperBound...]
        let body = after.range(of: "\n## ").map { after[..<$0.lowerBound] } ?? after
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func hms(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
