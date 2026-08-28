import Foundation

enum TranscriptTopicSuggester {
    private static let stopwords: Set<String> = [
        "about", "actually", "also", "and", "are", "because", "been", "being",
        "but", "can", "could", "data", "did", "does", "doing", "for", "from",
        "going", "good", "have", "here", "how", "into", "issue", "just", "know",
        "like", "make", "maybe", "meeting", "need", "now", "okay", "one", "our",
        "problem", "really", "right", "see", "should", "some", "than", "thank",
        "that", "the", "their", "them", "then", "there", "these", "they", "thing",
        "things", "think", "this", "those", "three", "two", "use", "used", "using",
        "very", "want", "was", "we", "were", "what", "when", "where", "which",
        "will", "with", "would", "yeah", "yes", "you", "your",
        "como", "con", "cuando", "datos", "del", "desde", "entonces", "esta",
        "este", "esto", "gracias", "hay", "los", "para", "pero", "por", "porque",
        "que", "sin", "son", "una", "vamos",
    ]

    static func slug(mic: [WhisperSegment], system: [WhisperSegment]) -> String? {
        let text = (mic + system)
            .sorted { $0.start < $1.start }
            .map(\.text)
            .joined(separator: " ")
        return slug(text)
    }

    static func slug(_ text: String) -> String? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter {
                $0.count >= 3
                    && !$0.allSatisfy(\.isNumber)
                    && !stopwords.contains($0)
            }
        guard !tokens.isEmpty else { return nil }

        let counts = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
        let firstIndex = Dictionary(
            tokens.enumerated().reversed().map { ($0.element, $0.offset) },
            uniquingKeysWith: { latest, _ in latest })
        let pairs = zip(tokens, tokens.dropFirst()).map { "\($0)-\($1)" }
        let pairCounts = Dictionary(pairs.map { ($0, 1) }, uniquingKeysWith: +)
        if let pair = pairCounts.keys.max(by: { left, right in
            let leftWords = left.split(separator: "-").map(String.init)
            let rightWords = right.split(separator: "-").map(String.init)
            let leftScore = pairCounts[left, default: 0] * 4
                + leftWords.reduce(0) { $0 + counts[$1, default: 0] }
            let rightScore = pairCounts[right, default: 0] * 4
                + rightWords.reduce(0) { $0 + counts[$1, default: 0] }
            if leftScore != rightScore { return leftScore < rightScore }
            return (firstIndex[leftWords[0]] ?? .max)
                > (firstIndex[rightWords[0]] ?? .max)
        }) {
            return RecordingSession.slug(pair)
        }

        let token = tokens.max {
            let left = counts[$0, default: 0]
            let right = counts[$1, default: 0]
            if left != right { return left < right }
            return (firstIndex[$0] ?? .max) > (firstIndex[$1] ?? .max)
        }
        return token.map(RecordingSession.slug)
    }
}
