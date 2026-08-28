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
                let micTokens = mText.split(separator: " ").map(String.init)
                let systemTokens = sText.split(separator: " ").map(String.init)
                let overlap = tokenOverlap(micTokens, systemTokens)
                let shorterCount = min(micTokens.count, systemTokens.count)
                let longerCount = max(micTokens.count, systemTokens.count)
                if shorterCount >= 3,
                   overlap >= 3,
                   Double(overlap) / Double(shorterCount) >= 0.75,
                   Double(overlap) / Double(longerCount) >= 0.45
                {
                    return false
                }
            }
            return true
        }
    }

    private static func tokenOverlap(_ left: [String], _ right: [String]) -> Int {
        var remaining = Dictionary(right.map { ($0, 1) }, uniquingKeysWith: +)
        return left.reduce(into: 0) { overlap, token in
            guard remaining[token, default: 0] > 0 else { return }
            overlap += 1
            remaining[token, default: 0] -= 1
        }
    }

    /// Whisper hallucinations that survive the decoder flags: sparse filler phrases,
    /// known phrases repeated while the remote speaker is talking, and single-token
    /// decoder loops. This runs before turn grouping so those artifacts never reach
    /// the output.
    static let repeatedHallucinationPhrases: Set<String> = [
        "thank you",
        "thanks",
        "thank you for watching",
        "thanks for watching",
        "gracias",
        "gracias por ver el video",
    ]
    static let fillerPhrases: Set<String> = repeatedHallucinationPhrases.union([
        "you",
        "bye",
        "okay",
        "yeah",
        "yes",
        "yep",
    ])
    static let repeatedHallucinationMinimumCount = 5
    static let repeatedTokenMinimumCount = 12
    /// A segment whose seconds-per-word exceeds this is too sparse to be real speech.
    static let maxSecondsPerWord: Double = 4.0

    static func dropHallucinations(
        _ segments: [WhisperSegment],
        overlapping otherSegments: [WhisperSegment] = []
    ) -> [WhisperSegment] {
        let grouped = Dictionary(grouping: segments) { normalize($0.text) }
        let repeatedOverlappingPhrases: Set<String> = Set(
            grouped.compactMap { phrase, matches -> String? in
                guard repeatedHallucinationPhrases.contains(phrase),
                      matches.count >= repeatedHallucinationMinimumCount
                else {
                    return nil
                }
                let overlappingCount = matches.filter { segment in
                    otherSegments.contains { other in
                        segment.start < other.end + echoTimeSlack
                            && segment.end > other.start - echoTimeSlack
                    }
                }.count
                return overlappingCount * 2 >= matches.count ? phrase : nil
            })

        var out: [WhisperSegment] = []
        for seg in segments {
            let norm = normalize(seg.text)
            let words = norm.split(separator: " ")
            guard !words.isEmpty else { continue }
            if repeatedOverlappingPhrases.contains(norm) { continue }
            if isRepeatedTokenLoop(words) { continue }

            // Filler phrase stretched over a long, sparse segment => silence hallucination.
            if fillerPhrases.contains(norm) {
                let secondsPerWord = (seg.end - seg.start) / Double(words.count)
                if secondsPerWord > maxSecondsPerWord { continue }
            }

            // Consecutive identical tiny phrase => decoder repetition loop; keep first only.
            if let last = out.last, normalize(last.text) == norm, words.count <= 2 { continue }

            out.append(seg)
        }
        return out
    }

    private static func isRepeatedTokenLoop(_ words: [Substring]) -> Bool {
        guard words.count >= repeatedTokenMinimumCount else { return false }
        let counts = Dictionary(words.map { (String($0), 1) }, uniquingKeysWith: +)
        guard counts.count <= 2, let dominantCount = counts.values.max() else {
            return false
        }
        return dominantCount * 100 >= words.count * 80
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(separator: " ").joined(separator: " ")
    }

    static func format(mic: [WhisperSegment], system: [WhisperSegment], header: TranscriptHeader) -> String {
        struct Tagged { let speaker: Speaker; let seg: WhisperSegment }
        let cleanMic = dropHallucinations(mic, overlapping: system)
        let cleanSystem = dropHallucinations(system)
        let all = (cleanMic.map { Tagged(speaker: .me, seg: $0) } + cleanSystem.map { Tagged(speaker: .them, seg: $0) })
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

        // Obsidian-style meeting note: YAML frontmatter matching the vault convention,
        // then a raw "## Transcript" body. A transcript agent may insert "## Summary"
        // above the transcript. Recording metadata (model/duration/cleanup) lives in a
        // trailing HTML comment so it stays out of the rendered note and the graph.
        var out = """
        ---
        date: \(header.date)
        attendees: []
        tags: [meeting, transcript]
        ---

        ## Transcript

        """
        for turn in turns {
            out += "\n[\(hms(turn.start))] **\(turn.speaker.rawValue):** \(turn.texts.joined(separator: " "))\n"
        }
        out += "\n\(metaComment(header))\n"
        return out
    }

    /// Trailing provenance line: `<!-- meetscribe: app=…, duration=…, model=…, cleaned=… -->`.
    static func metaComment(_ header: TranscriptHeader) -> String {
        "<!-- meetscribe: app=\(header.app), duration=\(header.duration), "
            + "model=\(header.model), cleaned=\(header.cleanedByClaude), "
            + "processor=\(header.cleanedByClaude ? "claude-code" : "none") -->"
    }

    /// Records the processor after a validated cleanup pass. The prompt forbids the
    /// processor itself from editing frontmatter or the metadata comment.
    static func markProcessed(_ markdown: String, by processorID: String) -> String {
        markdown.replacingOccurrences(
            of: "cleaned=false, processor=none -->",
            with: "cleaned=true, processor=\(RecordingSession.slug(processorID)) -->")
    }

    /// Extracts the body of the optional "## Summary" section,
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
