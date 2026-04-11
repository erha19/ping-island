import Foundation

struct UpdateReleaseNotes: Equatable, Sendable {
    let currentVersion: String
    let targetVersion: String
    let markdown: String
    let sourceURL: URL?
    let publishedAt: Date?

    var sections: [UpdateReleaseNotesSection] {
        UpdateReleaseNotesParser.sections(from: markdown)
    }

    func sections(locale: Locale) -> [UpdateReleaseNotesSection] {
        UpdateReleaseNotesParser.sections(from: markdown, locale: locale)
    }

    func localizedMarkdown(locale: Locale) -> String {
        UpdateReleaseNotesParser.localizedMarkdown(from: markdown, locale: locale)
    }
}

struct UpdateReleaseNotesSection: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let markdown: String
}

enum UpdateReleaseNotesParser {
    static func sections(from markdown: String, locale: Locale? = nil) -> [UpdateReleaseNotesSection] {
        let normalized = localizedMarkdown(from: markdown, locale: locale)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return []
        }

        var sections: [UpdateReleaseNotesSection] = []
        var currentTitle = "更新内容"
        var currentLines: [String] = []
        var sectionIndex = 0

        for line in normalized.components(separatedBy: "\n") {
            if let heading = headingTitle(in: line) {
                if !currentLines.isEmpty {
                    sections.append(
                        UpdateReleaseNotesSection(
                            id: "\(sectionIndex)-\(currentTitle)",
                            title: currentTitle,
                            markdown: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                    sectionIndex += 1
                    currentLines.removeAll(keepingCapacity: true)
                }

                currentTitle = heading
            } else {
                currentLines.append(line)
            }
        }

        if !currentLines.isEmpty {
            sections.append(
                UpdateReleaseNotesSection(
                    id: "\(sectionIndex)-\(currentTitle)",
                    title: currentTitle,
                    markdown: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        return sections.filter { !$0.markdown.isEmpty }
    }

    static func localizedMarkdown(from markdown: String, locale: Locale?) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return ""
        }

        let blocks = localizedBlocks(from: normalized)
        guard !blocks.isEmpty else {
            return normalized
        }

        let preferredLanguage = preferredLanguageCode(for: locale)
        if let preferredBlock = blocks[preferredLanguage] {
            return preferredBlock
        }

        if preferredLanguage != "en", let englishBlock = blocks["en"] {
            return englishBlock
        }

        return blocks.values.first ?? normalized
    }

    private static func headingTitle(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else {
            return nil
        }

        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredLanguageCode(for locale: Locale?) -> String {
        let languageCode = locale?.identifier.lowercased() ?? "en"
        return languageCode.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    private static func localizedBlocks(from markdown: String) -> [String: String] {
        let lines = markdown.components(separatedBy: "\n")
        var commonLines: [String] = []
        var currentLanguage: String?
        var blocks: [String: [String]] = [:]

        for line in lines {
            if let languageMarker = languageMarker(in: line) {
                currentLanguage = languageMarker
                if blocks[languageMarker] == nil {
                    blocks[languageMarker] = []
                }
                continue
            }

            if let currentLanguage {
                blocks[currentLanguage, default: []].append(line)
            } else {
                commonLines.append(line)
            }
        }

        return blocks.reduce(into: [:]) { partialResult, entry in
            let mergedLines = (commonLines + entry.value)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !mergedLines.isEmpty {
                partialResult[entry.key] = mergedLines
            }
        }
    }

    private static func languageMarker(in line: String) -> String? {
        switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "<!-- zh-Hans -->":
            return "zh-Hans"
        case "<!-- en -->":
            return "en"
        default:
            return nil
        }
    }
}
