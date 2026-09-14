//
//  SessionTextSanitizer.swift
//  PingIsland
//
//  Normalizes session text for display by removing client-injected boilerplate.
//

import Foundation

enum SessionTextSanitizer {
    /// Remove client-injected boilerplate without flattening conversation content.
    static func sanitizedMessageText(_ text: String?) -> String? {
        guard let text else { return nil }

        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)^Conversation info \(untrusted metadata\):\s*```json.*?```"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)^\s*Sender \(untrusted metadata\):\s*```json.*?```"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)^\s*System:\s*\[[^\]]+\]\s*Node:.*?(?:\n\s*\n|\z)"#,
            with: "",
            options: .regularExpression
        )
        // Kimi's desktop app prefixes every submitted turn with an awareness tag
        // (`<meta awareness="low" timestamp="..." />`), which would otherwise become
        // the session's visible title.
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)^\s*<meta\b[^>]*/>"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<system-reminder>.*?</system-reminder>"#,
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)<system-reminder>.*$"#,
            with: " ",
            options: .regularExpression
        )
        let scalars = cleaned.unicodeScalars
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let firstContent = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let lastContent = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else {
            return nil
        }

        // Trim surrounding blank lines without removing the first content line's indentation.
        let leadingNewline = scalars[..<firstContent].lastIndex { $0 == "\r" || $0 == "\n" }
        let trailingNewline = scalars[scalars.index(after: lastContent)...].firstIndex {
            $0 == "\r" || $0 == "\n"
        }
        let start = leadingNewline.map { scalars.index(after: $0) } ?? scalars.startIndex
        let end = trailingNewline ?? scalars.endIndex
        return String(scalars[start..<end])
    }

    static func sanitizedDisplayText(_ text: String?) -> String? {
        guard let cleaned = sanitizedMessageText(text) else { return nil }
        return cleaned
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func boundedDisplayText(
        _ text: String?,
        maxCharacters: Int,
        truncationNotice: String
    ) -> String? {
        guard let text else { return nil }
        guard !text.isEmpty else { return nil }
        guard maxCharacters > 0 else { return truncationNotice }

        guard let cutoff = text.index(
            text.startIndex,
            offsetBy: maxCharacters,
            limitedBy: text.endIndex
        ) else {
            return text
        }

        guard cutoff < text.endIndex else {
            return text
        }

        let prefix = text[..<cutoff].trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)\n\n\(truncationNotice)"
    }
}

enum SessionDetailDisplayStrings {
    static let truncationNoticeKey = "Showing a shortened preview to keep Ping Island responsive. Open the client to view the full content."
}
