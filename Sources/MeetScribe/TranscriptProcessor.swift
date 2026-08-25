import Foundation

struct TranscriptProcessingResult: Sendable {
    let markdown: String
    let topicSlug: String
}

protocol TranscriptProcessing: Sendable {
    var id: String { get }
    func process(_ markdown: String) throws -> TranscriptProcessingResult?
}

enum TranscriptProcessorSupport {
    static let standardTimeout: TimeInterval = 300
    static let longTranscriptTimeout: TimeInterval = 900
    static let longTranscriptThreshold = 50_000

    static let defaultPrompt = """
        You are a transcript editor. Clean up the meeting transcript below: fix punctuation and casing, \
        remove filler words and false starts, and merge fragments into coherent paragraphs. STRICT RULES: \
        keep every [hh:mm:ss] timestamp and every **Me:**/**Them:** label exactly as-is; keep each language \
        as spoken and do not translate; do not summarize, reorder, or omit content in the transcript body; \
        keep the YAML frontmatter and trailing <!-- meetscribe: ... --> comment exactly as-is.

        The first line must be exactly <!-- topic: <slug> -->, using 1-3 lowercase hyphen-separated words. \
        Insert a ## Summary section of 2-4 sentences after the frontmatter, followed by ## Transcript and \
        the complete cleaned transcript. Output only Markdown.
        """

    static func timeout(for markdown: String) -> TimeInterval {
        markdown.utf8.count >= longTranscriptThreshold
            ? longTranscriptTimeout
            : standardTimeout
    }

    static func extractTopic(_ text: String) -> (String?, String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("<!-- topic:"),
              first.hasSuffix("-->")
        else {
            return (nil, text)
        }
        let slug = RecordingSession.slug(
            first.dropFirst("<!-- topic:".count).dropLast("-->".count)
                .trimmingCharacters(in: .whitespaces))
        lines.removeFirst()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        let words = slug.split(separator: "-", omittingEmptySubsequences: true)
        guard !slug.isEmpty, (1...3).contains(words.count), slug.utf8.count <= 64 else {
            return (nil, body)
        }
        return (String(slug), body)
    }

    static func structurallyValid(original: String, processed: String) -> Bool {
        guard let summary = processed.range(of: "## Summary"),
              let transcript = processed.range(of: "## Transcript"),
              summary.lowerBound < transcript.lowerBound,
              frontmatter(in: original) == frontmatter(in: processed),
              metadataComment(in: original) == metadataComment(in: processed)
        else {
            return false
        }
        let originalTurns = transcriptTurns(in: original)
        let processedTurns = transcriptTurns(in: processed)
        guard originalTurns.map(\.marker) == processedTurns.map(\.marker) else {
            return false
        }

        let originalTokens = originalTurns.flatMap(\.tokens)
        let processedTokens = processedTurns.flatMap(\.tokens)
        guard !originalTokens.isEmpty else { return processedTokens.isEmpty }
        guard processedTokens.count <= Int(Double(originalTokens.count) * 1.5) + 8 else {
            return false
        }
        guard tokenOverlap(originalTokens, processedTokens) * 2 >= originalTokens.count else {
            return false
        }
        return zip(originalTurns, processedTurns).allSatisfy { originalTurn, processedTurn in
            originalTurn.tokens.isEmpty
                || tokenOverlap(originalTurn.tokens, processedTurn.tokens) > 0
        }
    }

    private static func frontmatter(in markdown: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---")
        else {
            return nil
        }
        return lines[...closing].joined(separator: "\n")
    }

    private static func metadataComment(in markdown: String) -> String? {
        markdown.split(separator: "\n").map(String.init)
            .first { $0.hasPrefix("<!-- meetscribe:") && $0.hasSuffix("-->") }
    }

    private struct TranscriptTurn {
        let marker: String
        let tokens: [String]
    }

    private static func transcriptTurns(in markdown: String) -> [TranscriptTurn] {
        let pattern = #"\[\d{2}:\d{2}:\d{2}\] \*\*(?:Me|Them):\*\*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let contentEnd = metadataCommentRange(in: markdown)?.lowerBound ?? markdown.endIndex
        let content = String(markdown[..<contentEnd])
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        return matches.enumerated().compactMap { index, match in
            guard let markerRange = Range(match.range, in: content) else { return nil }
            let textStart = markerRange.upperBound
            let textEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: content)
            {
                textEnd = nextRange.lowerBound
            } else {
                textEnd = content.endIndex
            }
            return TranscriptTurn(
                marker: String(content[markerRange]),
                tokens: tokens(in: String(content[textStart..<textEnd])))
        }
    }

    private static func metadataCommentRange(in markdown: String) -> Range<String.Index>? {
        markdown.range(of: "<!-- meetscribe:")
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func tokenOverlap(_ left: [String], _ right: [String]) -> Int {
        var remaining = Dictionary(right.map { ($0, 1) }, uniquingKeysWith: +)
        var overlap = 0
        for token in left where remaining[token, default: 0] > 0 {
            overlap += 1
            remaining[token, default: 0] -= 1
        }
        return overlap
    }
}

struct ClaudeCodeTranscriptProcessor: TranscriptProcessing {
    let id = "claude-code"

    func process(_ markdown: String) throws -> TranscriptProcessingResult? {
        guard let result = try ClaudeCleaner.clean(markdown) else { return nil }
        return TranscriptProcessingResult(
            markdown: result.markdown,
            topicSlug: result.topicSlug)
    }
}

struct KiroCLITranscriptProcessor: TranscriptProcessing {
    let id = "kiro-cli"

    func process(_ markdown: String) throws -> TranscriptProcessingResult? {
        guard let result = try KiroCleaner.clean(markdown) else { return nil }
        return TranscriptProcessingResult(
            markdown: result.markdown,
            topicSlug: result.topicSlug)
    }
}

struct CommandTranscriptProcessor: TranscriptProcessing {
    let id = "custom-command"
    let configuration: AgentConfiguration

    enum ProcessorError: Error, LocalizedError {
        case missingExecutable
        case missingTopic
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .missingExecutable:
                "Choose an executable for the custom transcript agent."
            case .missingTopic:
                "The custom transcript agent returned a transcript without the required topic name."
            case .invalidOutput:
                "The custom transcript agent returned incomplete or structurally unsafe Markdown."
            }
        }
    }

    func process(_ markdown: String) throws -> TranscriptProcessingResult? {
        let executable = (configuration.customExecutable as NSString).expandingTildeInPath
        guard executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable)
        else {
            throw ProcessorError.missingExecutable
        }

        var replacedPrompt = false
        var arguments = configuration.customArguments.map { argument in
            guard argument.contains("{prompt}") else { return argument }
            replacedPrompt = true
            return argument.replacingOccurrences(
                of: "{prompt}",
                with: configuration.customPrompt)
        }
        if !replacedPrompt {
            arguments.append(configuration.customPrompt)
        }

        let output = try Subprocess.run(
            executable,
            arguments,
            stdin: markdown,
            timeout: TranscriptProcessorSupport.timeout(for: markdown),
            environment: configuration.inheritEnvironment
                ? ProcessInfo.processInfo.environment
                : Subprocess.restrictedEnvironment)
        let (slug, body) = TranscriptProcessorSupport.extractTopic(output)
        guard let slug else {
            throw ProcessorError.missingTopic
        }
        guard TranscriptProcessorSupport.structurallyValid(original: markdown, processed: body) else {
            throw ProcessorError.invalidOutput
        }
        return TranscriptProcessingResult(markdown: body, topicSlug: slug)
    }
}

enum TranscriptProcessorFactory {
    static func make(configuration: AgentConfiguration) -> (any TranscriptProcessing)? {
        switch configuration.provider {
        case .disabled:
            nil
        case .claudeCode:
            ClaudeCodeTranscriptProcessor()
        case .kiroCLI:
            KiroCLITranscriptProcessor()
        case .customCommand:
            CommandTranscriptProcessor(configuration: configuration)
        }
    }
}
