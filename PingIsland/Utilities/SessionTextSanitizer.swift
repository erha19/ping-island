//
//  SessionTextSanitizer.swift
//  PingIsland
//
//  Normalizes session text for display by removing client-injected boilerplate.
//

import Foundation

enum SessionTextSanitizer {
    static func sanitizedDisplayText(_ text: String?) -> String? {
        guard let text else { return nil }

        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)^Conversation info \(untrusted metadata\):\s*```json.*?```\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)^Sender \(untrusted metadata\):\s*```json.*?```\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?is)^System:\s*\[[^\]]+\]\s*Node:.*?(?:\n\s*\n|\z)"#,
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
        cleaned = cleaned
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
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
