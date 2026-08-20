import Foundation

struct TranscriptProcessingResult: Sendable {
    let markdown: String
    let topicSlug: String?
}

protocol TranscriptProcessing: Sendable {
    var id: String { get }
    func process(_ markdown: String) throws -> TranscriptProcessingResult?
}

enum TranscriptProcessorSupport {
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
        return (slug.isEmpty ? nil : String(slug), body)
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
        return turnMarkers(in: original) == turnMarkers(in: processed)
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

    private static func turnMarkers(in markdown: String) -> [String] {
        let pattern = #"\[\d{2}:\d{2}:\d{2}\] \*\*(?:Me|Them):\*\*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.matches(in: markdown, range: range).compactMap {
            Range($0.range, in: markdown).map { String(markdown[$0]) }
        }
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

struct CommandTranscriptProcessor: TranscriptProcessing {
    let id = "custom-command"
    let configuration: AgentConfiguration

    enum ProcessorError: Error, LocalizedError {
        case missingExecutable
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .missingExecutable:
                "Choose an executable for the custom transcript agent."
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
            timeout: 300,
            environment: configuration.inheritEnvironment
                ? ProcessInfo.processInfo.environment
                : Subprocess.restrictedEnvironment)
        let (slug, body) = TranscriptProcessorSupport.extractTopic(output)
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
        case .customCommand:
            CommandTranscriptProcessor(configuration: configuration)
        }
    }
}
