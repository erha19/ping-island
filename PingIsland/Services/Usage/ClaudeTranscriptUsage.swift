import Foundation

struct ClaudeTranscriptUsageSnapshot: Equatable, Sendable {
    let sourceFilePath: String
    let capturedAt: Date?
    let fileSize: UInt64
    let contentHash: String
    let tokenTotals: AgentUsageTokenTotals
}

enum ClaudeTranscriptUsageLoader {
    private nonisolated static let defaultMaxBytesPerFile = 64 * 1024 * 1024

    nonisolated static func load(
        from fileURL: URL,
        fileManager: FileManager = .default,
        maxBytesPerFile: Int = defaultMaxBytesPerFile
    ) throws -> ClaudeTranscriptUsageSnapshot? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
        guard resourceValues.isRegularFile != false else {
            return nil
        }

        let fileSize = UInt64(max(0, resourceValues.fileSize ?? 0))
        guard fileSize > 0, fileSize <= UInt64(max(0, maxBytesPerFile)) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let content = String(decoding: data, as: UTF8.self)
        var totals = AgentUsageTokenTotals()
        var latestUsageDate: Date?

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let object = jsonObject(for: line),
                  let lineTotals = usageTotals(from: object) else {
                continue
            }

            totals.add(lineTotals)
            if let lineDate = timestamp(from: object["timestamp"]),
               latestUsageDate == nil || lineDate > latestUsageDate! {
                latestUsageDate = lineDate
            }
        }

        guard totals.hasTokens else {
            return nil
        }

        return ClaudeTranscriptUsageSnapshot(
            sourceFilePath: fileURL.path,
            capturedAt: latestUsageDate ?? resourceValues.contentModificationDate,
            fileSize: UInt64(data.count),
            contentHash: fnv1aHashHex(for: data),
            tokenTotals: totals
        )
    }

    private nonisolated static func usageTotals(from object: [String: Any]) -> AgentUsageTokenTotals? {
        if let totals = tokenTotals(from: object["usage"])
            ?? tokenTotals(from: object["token_usage"])
            ?? tokenTotals(from: object["total_token_usage"]) {
            return totals
        }

        if let message = object["message"] as? [String: Any] {
            if let totals = tokenTotals(from: message["usage"])
                ?? tokenTotals(from: message["token_usage"])
                ?? tokenTotals(from: message["usage_metadata"])
                ?? tokenTotals(from: message["total_token_usage"])
                ?? tokenTotals(from: message) {
                return totals
            }
        }

        return tokenTotals(from: object)
    }

    private nonisolated static func tokenTotals(from value: Any?) -> AgentUsageTokenTotals? {
        guard let payload = value as? [String: Any] else {
            return nil
        }

        if let nested = tokenTotals(from: payload["usage"])
            ?? tokenTotals(from: payload["token_usage"])
            ?? tokenTotals(from: payload["total_token_usage"]) {
            return nested
        }

        let baseInput = integer(from: payload["input_tokens"])
            ?? integer(from: payload["inputTokens"])
            ?? integer(from: payload["prompt_tokens"])
            ?? integer(from: payload["promptTokens"])
            ?? 0
        let cacheCreation = integer(from: payload["cache_creation_input_tokens"])
            ?? integer(from: payload["cacheCreationInputTokens"])
            ?? 0
        let cacheRead = integer(from: payload["cache_read_input_tokens"])
            ?? integer(from: payload["cacheReadInputTokens"])
            ?? 0
        let output = integer(from: payload["output_tokens"])
            ?? integer(from: payload["outputTokens"])
            ?? integer(from: payload["completion_tokens"])
            ?? integer(from: payload["completionTokens"])
            ?? 0
        let total = integer(from: payload["total_tokens"])
            ?? integer(from: payload["totalTokens"])
            ?? integer(from: payload["total_token_count"])
            ?? integer(from: payload["totalTokenCount"])
            ?? integer(from: payload["total"])
            ?? 0
        let input = baseInput + cacheCreation + cacheRead
        let resolvedTotal = total > 0 ? total : input + output

        guard input > 0 || output > 0 || resolvedTotal > 0 else {
            return nil
        }

        return AgentUsageTokenTotals(
            input: input,
            output: output,
            total: resolvedTotal
        )
    }

    private nonisolated static func jsonObject(for line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private nonisolated static func integer(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private nonisolated static func timestamp(from value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: string) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        default:
            return nil
        }
    }

    private nonisolated static func fnv1aHashHex(for data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
