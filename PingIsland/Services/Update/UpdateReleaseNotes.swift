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
}

struct UpdateReleaseNotesSection: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let markdown: String
}

enum UpdateReleaseNotesParser {
    static func sections(from markdown: String) -> [UpdateReleaseNotesSection] {
        let normalized = markdown
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

    private static func headingTitle(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else {
            return nil
        }

        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
