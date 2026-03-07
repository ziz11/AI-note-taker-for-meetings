import Foundation

enum SummaryOutputParser {
    static func parse(_ rawMarkdown: String) throws -> SummaryDocument {
        let trimmed = rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummarizationError.emptyOutput
        }

        let topics = extractBullets(
            underAny: ["## Topics", "## Ключевые темы", "1. Ключевые темы"],
            in: trimmed
        )
        let decisions = extractBullets(
            underAny: ["## Decisions", "## Основные решения", "2. Основные решения"],
            in: trimmed
        )
        let actionItems = extractBullets(
            underAny: ["## Action Items", "## Следующие шаги", "3. Следующие шаги"],
            in: trimmed
        )
        let risks = extractBullets(
            underAny: ["## Risks", "## Риски и открытые вопросы", "4. Риски и открытые вопросы"],
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
}
