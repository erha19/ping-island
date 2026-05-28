import Foundation

struct CodexUsageWindow: Equatable, Codable, Sendable, Identifiable {
    let key: String
    let label: String
    let usedPercentage: Double
    let leftPercentage: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var id: String { key }

    var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

struct CodexUsageSnapshot: Equatable, Codable, Sendable {
    let sourceFilePath: String
    let capturedAt: Date?
    let planType: String?
    let limitID: String?
    let tokenUsage: CodexTokenUsage?
    let windows: [CodexUsageWindow]

    nonisolated init(
        sourceFilePath: String,
        capturedAt: Date?,
        planType: String?,
        limitID: String?,
        tokenUsage: CodexTokenUsage? = nil,
        windows: [CodexUsageWindow]
    ) {
        self.sourceFilePath = sourceFilePath
        self.capturedAt = capturedAt
        self.planType = planType
        self.limitID = limitID
        self.tokenUsage = tokenUsage
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case sourceFilePath
        case capturedAt
        case planType
        case limitID
        case tokenUsage
        case windows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceFilePath = try container.decode(String.self, forKey: .sourceFilePath)
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        limitID = try container.decodeIfPresent(String.self, forKey: .limitID)
        tokenUsage = try container.decodeIfPresent(CodexTokenUsage.self, forKey: .tokenUsage)
        windows = try container.decode([CodexUsageWindow].self, forKey: .windows)
    }

    nonisolated var threadID: String? {
        let stem = URL(fileURLWithPath: sourceFilePath).deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else { return nil }

        let candidate = String(stem.suffix(36)).lowercased()
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }

    nonisolated
    var isEmpty: Bool {
        windows.isEmpty
    }
}

enum CodexUsageLoader {
    nonisolated static let defaultRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    private struct Candidate {
        let fileURL: URL
        let modifiedAt: Date
    }

    nonisolated static func load(
        fromRootURL rootURL: URL = defaultRootURL,
        fileManager: FileManager = .default
    ) throws -> CodexUsageSnapshot? {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var candidates: [Candidate] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl",
                  let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  resourceValues.isRegularFile == true else {
                continue
            }

            candidates.append(
                Candidate(
                    fileURL: fileURL,
                    modifiedAt: resourceValues.contentModificationDate ?? .distantPast
                )
            )
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.fileURL.path.localizedStandardCompare(rhs.fileURL.path) == .orderedDescending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }

        var bestSnapshot: CodexUsageSnapshot?
        var bestCapturedAt: Date = .distantPast

        for candidate in sortedCandidates {
            guard let snapshot = loadLatestSnapshot(from: candidate.fileURL, modifiedAt: candidate.modifiedAt) else {
                continue
            }
            let capturedAt = snapshot.capturedAt ?? candidate.modifiedAt
            if capturedAt > bestCapturedAt {
                bestSnapshot = snapshot
                bestCapturedAt = capturedAt
            }
        }

        return bestSnapshot
    }

    private nonisolated static func loadLatestSnapshot(from fileURL: URL, modifiedAt: Date) -> CodexUsageSnapshot? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        var latestSnapshot: CodexUsageSnapshot?
        contents.enumerateLines { line, _ in
            guard let snapshot = snapshot(from: line, filePath: fileURL.path, fallbackTimestamp: modifiedAt) else {
                return
            }
            latestSnapshot = snapshot
        }
        return latestSnapshot
    }

    private nonisolated static func snapshot(from line: String, filePath: String, fallbackTimestamp: Date) -> CodexUsageSnapshot? {
        guard let object = jsonObject(for: line),
              object["type"] as? String == "event_msg" else {
            return nil
        }

        let payload = object["payload"] as? [String: Any] ?? [:]
        guard payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any] else {
            return nil
        }

        let windows = ["primary", "secondary"].compactMap { key in
            usageWindow(for: key, in: rateLimits)
        }
        guard !windows.isEmpty else {
            return nil
        }

        return CodexUsageSnapshot(
            sourceFilePath: filePath,
            capturedAt: timestamp(from: object["timestamp"]) ?? fallbackTimestamp,
            planType: string(from: rateLimits["plan_type"]),
            limitID: string(from: rateLimits["limit_id"]),
            tokenUsage: tokenUsage(from: payload["info"]),
            windows: windows
        )
    }

    private nonisolated static func usageWindow(for key: String, in rateLimits: [String: Any]) -> CodexUsageWindow? {
        guard let payload = rateLimits[key] as? [String: Any],
              let usedPercentage = number(from: payload["used_percent"]),
              let windowMinutes = integer(from: payload["window_minutes"]) else {
            return nil
        }

        return CodexUsageWindow(
            key: key,
            label: windowLabel(forMinutes: windowMinutes),
            usedPercentage: usedPercentage,
            leftPercentage: max(0, 100 - usedPercentage),
            windowMinutes: windowMinutes,
            resetsAt: date(from: payload["resets_at"])
        )
    }

    private nonisolated static func windowLabel(forMinutes minutes: Int) -> String {
        let days = minutes / 1_440
        let remainingMinutesAfterDays = minutes % 1_440
        let hours = remainingMinutesAfterDays / 60
        let remainingMinutes = remainingMinutesAfterDays % 60

        if days > 0, hours == 0, remainingMinutes == 0 {
            return "\(days)d"
        }
        if days > 0, hours > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0, remainingMinutes == 0 {
            return "\(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(minutes)m"
    }

    private nonisolated static func jsonObject(for line: String) -> [String: Any]? {
        guard !line.isEmpty else {
            return nil
        }

        let data = Data(line.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private nonisolated static func timestamp(from value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private nonisolated static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private nonisolated static func integer(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private nonisolated static func date(from value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            guard let seconds = Double(string) else {
                return nil
            }
            return Date(timeIntervalSince1970: seconds)
        default:
            return nil
        }
    }

    private nonisolated static func string(from value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private nonisolated static func tokenUsage(from value: Any?) -> CodexTokenUsage? {
        let usage: [String: Any]?
        if let info = value as? [String: Any] {
            usage = info["total_token_usage"] as? [String: Any]
        } else {
            usage = nil
        }

        guard let usage else {
            return nil
        }

        let inputTokens = integer(from: usage["input_tokens"])
            ?? integer(from: usage["prompt_tokens"])
            ?? 0
        let outputTokens = integer(from: usage["output_tokens"])
            ?? integer(from: usage["completion_tokens"])
            ?? 0
        let totalTokens = integer(from: usage["total_tokens"])
            ?? max(0, inputTokens + outputTokens)

        guard inputTokens > 0 || outputTokens > 0 || totalTokens > 0 else {
            return nil
        }

        return CodexTokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens
        )
    }
}
