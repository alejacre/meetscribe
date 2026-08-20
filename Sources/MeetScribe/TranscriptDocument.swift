import Foundation

struct TranscriptTurn: Equatable, Sendable {
    let timestamp: String
    let speaker: String
    let text: String
}

struct TranscriptDocument: Equatable, Sendable {
    let title: String
    let date: String?
    let tags: [String]
    let summary: String?
    let decisions: [String]
    let turns: [TranscriptTurn]
    let unstructuredTranscript: String?
    let sourceApp: String?
    let duration: String?
    let rawMarkdown: String

    var searchableText: String {
        [
            title,
            date ?? "",
            tags.joined(separator: " "),
            summary ?? "",
            decisions.joined(separator: " "),
            turns.map { "\($0.speaker) \($0.text)" }.joined(separator: " "),
            unstructuredTranscript ?? "",
            rawMarkdown,
        ].joined(separator: " ")
    }

    static func load(from url: URL) throws -> TranscriptDocument {
        parse(
            try String(contentsOf: url, encoding: .utf8),
            filename: url.deletingPathExtension().lastPathComponent)
    }

    static func parse(_ markdown: String, filename: String) -> TranscriptDocument {
        let lines = markdown.components(separatedBy: .newlines)
        let frontmatter = parseFrontmatter(lines)
        let sections = parseSections(lines)
        let summary = cleanParagraphs(sections["summary"] ?? [])
        let decisions = (sections["decisions"] ?? []).compactMap(cleanListItem)
        let transcript = parseTranscript(sections["transcript"] ?? [])
        let metadata = parseMetadata(lines)

        return TranscriptDocument(
            title: title(from: filename),
            date: frontmatter["date"],
            tags: parseTags(frontmatter["tags"]),
            summary: summary.isEmpty ? nil : summary,
            decisions: decisions,
            turns: transcript.turns,
            unstructuredTranscript: transcript.unstructured,
            sourceApp: metadata["app"],
            duration: metadata["duration"],
            rawMarkdown: markdown)
    }

    static func title(from filename: String) -> String {
        filename
    }

    private static func parseFrontmatter(_ lines: [String]) -> [String: String] {
        guard lines.first == "---" else { return [:] }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }

    private static func parseSections(_ lines: [String]) -> [String: [String]] {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in lines {
            if line.hasPrefix("## ") {
                current = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                continue
            }
            guard let current else { continue }
            sections[current, default: []].append(line)
        }
        return sections
    }

    private static func cleanParagraphs(_ lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .drop(while: \.isEmpty)
            .reversed()
            .drop(while: \.isEmpty)
            .reversed()
            .joined(separator: "\n")
    }

    private static func cleanListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefixes = ["- ", "* ", "• "]
        guard let prefix = prefixes.first(where: trimmed.hasPrefix) else { return nil }
        let item = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }

    private static func parseTurn(_ line: String) -> TranscriptTurn? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              let timeEnd = trimmed.firstIndex(of: "]")
        else {
            return nil
        }
        let timestamp = String(trimmed[trimmed.index(after: trimmed.startIndex)..<timeEnd])
        let remainder = trimmed[trimmed.index(after: timeEnd)...]
            .trimmingCharacters(in: .whitespaces)
        guard remainder.hasPrefix("**"),
              let speakerEnd = remainder.range(of: ":**")
        else {
            return nil
        }
        let speaker = String(remainder.dropFirst(2)[..<speakerEnd.lowerBound])
        let text = remainder[speakerEnd.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty, !text.isEmpty else { return nil }
        return TranscriptTurn(timestamp: timestamp, speaker: speaker, text: text)
    }

    private static func parseTranscript(
        _ lines: [String]
    ) -> (turns: [TranscriptTurn], unstructured: String?) {
        var turns: [TranscriptTurn] = []
        var unstructured: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.contains("<!-- meetscribe:") else { continue }
            if let turn = parseTurn(line) {
                turns.append(turn)
            } else if !trimmed.isEmpty, let previous = turns.popLast() {
                turns.append(TranscriptTurn(
                    timestamp: previous.timestamp,
                    speaker: previous.speaker,
                    text: previous.text + "\n" + trimmed))
            } else {
                unstructured.append(line)
            }
        }

        let fallback = cleanParagraphs(unstructured)
        return (turns, fallback.isEmpty ? nil : fallback)
    }

    private static func parseTags(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseMetadata(_ lines: [String]) -> [String: String] {
        guard let line = lines.last(where: { $0.contains("<!-- meetscribe:") }),
              let start = line.range(of: "<!-- meetscribe:"),
              let end = line.range(of: "-->", options: .backwards),
              start.upperBound <= end.lowerBound
        else {
            return [:]
        }
        let body = line[start.upperBound..<end.lowerBound]
        return body.split(separator: ",").reduce(into: [:]) { values, part in
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            values[key] = pair[1].trimmingCharacters(in: .whitespaces)
        }
    }
}
