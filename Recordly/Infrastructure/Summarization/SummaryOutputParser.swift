import Foundation

enum SummaryOutputParser {
    static func parse(_ rawMarkdown: String) throws -> SummaryDocument {
        let trimmed = sanitize(rawMarkdown)
        guard !trimmed.isEmpty else {
            throw SummarizationError.emptyOutput
        }

        let topics = extractBullets(
            underAny: [
                "## Topics",
                "## Topic Agreements",
                "## Topics and Agreements",
                "## Темы",
                "## Темы и договоренности",
                "## Ключевые темы",
                "1. Ключевые темы"
            ],
            in: trimmed
        )
        let decisions = extractBullets(
            underAny: [
                "## Decisions",
                "## Decisions and Agreements",
                "## Решения",
                "## Решения и договоренности",
                "## Основные решения",
                "2. Основные решения"
            ],
            in: trimmed
        )
        let actionItems = extractBullets(
            underAny: [
                "## Action Items",
                "## Follow-ups",
                "## Следующие шаги",
                "3. Следующие шаги"
            ],
            in: trimmed
        )
        let risks = extractBullets(
            underAny: [
                "## Risks",
                "## Open Risks",
                "## Риски",
                "## Риски и открытые вопросы",
                "4. Риски и открытые вопросы"
            ],
            in: trimmed
        )

        return SummaryDocument(
            topics: topics,
            decisions: decisions,
            actionItems: actionItems,
            risks: risks,
            rawMarkdown: trimmed
        )
    }

    private static func extractBullets(underAny headings: [String], in text: String) -> [String] {
        guard let headingRange = firstHeadingRange(in: text, headings: headings) else {
            return []
        }

        let afterHeading = text[headingRange.upperBound...]

        let nextHeadingPattern = try! NSRegularExpression(pattern: "^(## |\\d+\\. )", options: .anchorsMatchLines)
        let afterString = String(afterHeading)
        let sectionEnd: String.Index
        if let match = nextHeadingPattern.firstMatch(
            in: afterString,
            range: NSRange(afterString.startIndex..., in: afterString)
        ), match.range.location > 0 {
            sectionEnd = afterString.index(afterString.startIndex, offsetBy: match.range.location)
        } else {
            sectionEnd = afterString.endIndex
        }

        let section = afterString[afterString.startIndex..<sectionEnd]
        return section
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
            .deduplicatedSummaryBullets()
    }

    private static func firstHeadingRange(in text: String, headings: [String]) -> Range<String.Index>? {
        var firstRange: Range<String.Index>?
        for heading in headings {
            guard let range = text.range(of: heading, options: [.caseInsensitive]) else {
                continue
            }
            if let current = firstRange {
                if range.lowerBound < current.lowerBound {
                    firstRange = range
                }
            } else {
                firstRange = range
            }
        }
        return firstRange
    }

    private static func sanitize(_ rawMarkdown: String) -> String {
        let withoutThinkBlocks = rawMarkdown.replacingOccurrences(
            of: "(?is)<think>.*?</think>",
            with: "",
            options: .regularExpression
        )
        let trimmed = withoutThinkBlocks.trimmingCharacters(in: .whitespacesAndNewlines)
        let structured = structuredMarkdownSlice(from: trimmed)
        return deduplicateBullets(in: stripRuntimeStats(from: structured))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func structuredMarkdownSlice(from text: String) -> String {
        let headings = [
            "## Call Summary",
            "## Topics",
            "## Topic Agreements",
            "## Topics and Agreements",
            "## Саммари звонка",
            "## Темы",
            "## Темы и договоренности",
            "1. Ключевые темы"
        ]
        guard let firstRange = firstHeadingRange(in: text, headings: headings) else {
            return text
        }
        return String(text[firstRange.lowerBound...])
    }

    private static func stripRuntimeStats(from text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                return !trimmedLine.hasPrefix("==========")
                    && !trimmedLine.hasPrefix("Prompt:")
                    && !trimmedLine.hasPrefix("Generation:")
                    && !trimmedLine.hasPrefix("Peak memory:")
            }
            .joined(separator: "\n")
    }

    private static func deduplicateBullets(in text: String) -> String {
        var seenInSection: Set<String> = []
        var lines: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("## ") || trimmedLine.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                seenInSection.removeAll()
            }

            if trimmedLine.hasPrefix("- ") {
                let key = normalizedBulletKey(String(trimmedLine.dropFirst(2)))
                guard seenInSection.insert(key).inserted else {
                    continue
                }
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    private static func normalizedBulletKey(_ bullet: String) -> String {
        bullet
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private extension Array where Element == String {
    func deduplicatedSummaryBullets() -> [String] {
        var seen: Set<String> = []
        return filter { bullet in
            seen.insert(
                bullet
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            ).inserted
        }
    }
}
