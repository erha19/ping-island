//
//  SessionTextSanitizer.swift
//  PingIsland
//
//  Normalizes session text for display by removing client-injected boilerplate.
//

import Foundation

nonisolated enum SessionTextSanitizer {
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
}
