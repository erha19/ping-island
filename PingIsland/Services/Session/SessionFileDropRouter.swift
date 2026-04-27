import Foundation

enum SessionFileDropRouter {
    nonisolated static func prompt(for urls: [URL]) -> String {
        let normalizedPaths = urls
            .map { $0.path }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !normalizedPaths.isEmpty else {
            return ""
        }

        let bulletList = normalizedPaths
            .map { "- \($0)" }
            .joined(separator: "\n")

        return """
        Files dropped on Ping Island. Please use these local paths as context:
        \(bulletList)
        """
    }

    nonisolated static func failureMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "File drop failed." : message
    }
}
