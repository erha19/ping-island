import Foundation

struct ApprovalReviewDigest: Equatable, Sendable {
    enum Risk: String, Equatable, Sendable {
        case low
        case medium
        case high

        var title: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
    }

    let toolName: String
    let files: [String]
    let command: String?
    let patchSummary: String?
    let planSummary: String?
    let risk: Risk
    let riskReason: String
    let compactInput: String?

    init(
        toolName: String,
        formattedInput: String?,
        permission: PermissionContext?,
        intervention: SessionIntervention?
    ) {
        self.toolName = toolName

        let rawInput = Self.inputDictionary(permission: permission, intervention: intervention)
        let stringInput = rawInput.mapValues(Self.stringifyValue(_:))
        let fileKeys = ["file_path", "filePath", "path", "notebook_path", "old_path", "new_path", "target", "cwd"]
        self.files = fileKeys.compactMap { stringInput[$0]?.nonEmptyForReview }.uniquedForReview()
        self.command = (stringInput["command"] ?? stringInput["script"] ?? stringInput["cmd"])?.nonEmptyForReview
        self.patchSummary = Self.patchSummary(toolName: toolName, input: stringInput)
        self.planSummary = Self.planSummary(toolName: toolName, input: stringInput, fallback: formattedInput)
        let risk = Self.risk(toolName: toolName, command: command, files: files, input: stringInput)
        self.risk = risk.level
        self.riskReason = risk.reason
        self.compactInput = formattedInput?.nonEmptyForReview
    }

    var hasDetails: Bool {
        !files.isEmpty
            || command != nil
            || patchSummary != nil
            || planSummary != nil
            || compactInput != nil
            || risk != .low
    }

    nonisolated private static func inputDictionary(
        permission: PermissionContext?,
        intervention: SessionIntervention?
    ) -> [String: Any] {
        if let input = permission?.toolInput {
            return input.mapValues(\.value)
        }

        guard let rawJSON = intervention?.metadata["toolInputJSON"]
            ?? intervention?.metadata["tool_input_json"],
            let data = rawJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        return object
    }

    nonisolated private static func stringifyValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return String(describing: value)
        }
    }

    nonisolated private static func patchSummary(toolName: String, input: [String: String]) -> String? {
        let normalizedTool = toolName.lowercased()
        if let diff = (input["diff"] ?? input["patch"])?.nonEmptyForReview {
            return diff.reviewTruncated(to: 320)
        }

        if normalizedTool.contains("edit") {
            let oldValue = input["old_string"] ?? input["oldString"]
            let newValue = input["new_string"] ?? input["newString"]
            if let oldValue, let newValue {
                return "Replace \(oldValue.count) chars with \(newValue.count) chars"
            }
            return "Edit request"
        }

        if normalizedTool.contains("write") {
            let contentLength = (input["content"] ?? "").count
            return contentLength > 0 ? "Write \(contentLength) chars" : "Write request"
        }

        return nil
    }

    nonisolated private static func planSummary(
        toolName: String,
        input: [String: String],
        fallback: String?
    ) -> String? {
        let candidates = [
            input["plan"],
            input["summary"],
            input["content"],
            fallback
        ]
        let candidate = candidates.compactMap { $0?.nonEmptyForReview }.first
        guard toolName.localizedCaseInsensitiveContains("plan"),
              let candidate else {
            return nil
        }
        return candidate
            .split(separator: "\n")
            .prefix(8)
            .joined(separator: "\n")
            .reviewTruncated(to: 700)
    }

    nonisolated private static func risk(
        toolName: String,
        command: String?,
        files: [String],
        input: [String: String]
    ) -> (level: Risk, reason: String) {
        let lowerTool = toolName.lowercased()
        let lowerCommand = command?.lowercased() ?? ""
        let joinedInput = input.values.joined(separator: "\n").lowercased()

        let destructiveNeedles = [
            "rm -rf", "sudo rm", "git reset --hard", "mkfs", "diskutil erase",
            "chmod -r 777", "chown -r", "delete all", "drop database"
        ]
        if destructiveNeedles.contains(where: { lowerCommand.contains($0) || joinedInput.contains($0) }) {
            return (.high, "Destructive command or broad delete pattern detected.")
        }

        if lowerTool.contains("write")
            || lowerTool.contains("edit")
            || lowerTool.contains("multiedit")
            || lowerTool.contains("patch") {
            return (.medium, files.isEmpty ? "File mutation request." : "Will modify \(files.count) file path(s).")
        }

        let externalNeedles = ["curl ", "wget ", "git push", "gh pr merge", "npm publish"]
        if externalNeedles.contains(where: { lowerCommand.contains($0) }) {
            return (.medium, "Command touches network, publishing, or remote state.")
        }

        return (.low, "No destructive pattern detected.")
    }
}

private extension Array where Element == String {
    func uniquedForReview() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nonEmptyForReview: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func reviewTruncated(to length: Int) -> String {
        guard count > length else { return self }
        return String(prefix(length)) + "..."
    }
}
