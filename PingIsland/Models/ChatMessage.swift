//
//  ChatMessage.swift
//  PingIsland
//
//  Models for conversation messages parsed from JSONL
//

import Foundation

struct MessageTokenUsage: Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int

    nonisolated var totalTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens + outputTokens
    }

    static let zero = MessageTokenUsage(inputTokens: 0, outputTokens: 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 0)
}

struct SessionTokenUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int
    var cacheReadInputTokens: Int
    var turnCount: Int
    var firstTurnTimestamp: Date?
    var lastTurnTimestamp: Date?

    nonisolated var totalTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens + outputTokens
    }

    nonisolated var tokensPerSecond: Double? {
        guard let first = firstTurnTimestamp,
              let last = lastTurnTimestamp,
              turnCount > 1 else { return nil }
        let elapsed = last.timeIntervalSince(first)
        guard elapsed > 0 else { return nil }
        return Double(totalTokens) / elapsed
    }

    nonisolated var outputTokensPerSecond: Double? {
        guard let first = firstTurnTimestamp,
              let last = lastTurnTimestamp,
              turnCount > 1 else { return nil }
        let elapsed = last.timeIntervalSince(first)
        guard elapsed > 0 else { return nil }
        return Double(outputTokens) / elapsed
    }

    static let zero = SessionTokenUsage(inputTokens: 0, outputTokens: 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, turnCount: 0)

    mutating func accumulate(_ usage: MessageTokenUsage, timestamp: Date) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheCreationInputTokens += usage.cacheCreationInputTokens
        cacheReadInputTokens += usage.cacheReadInputTokens
        turnCount += 1
        if firstTurnTimestamp == nil { firstTurnTimestamp = timestamp }
        lastTurnTimestamp = timestamp
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: ChatRole
    let timestamp: Date
    let content: [MessageBlock]
    let usage: MessageTokenUsage?

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }

    /// Plain text content combined
    var textContent: String {
        content.compactMap { block in
            if case .text(let text) = block {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }
}

enum ChatRole: String, Equatable {
    case user
    case assistant
    case system
}

enum MessageBlock: Equatable, Identifiable {
    case text(String)
    case toolUse(ToolUseBlock)
    case thinking(String)
    case interrupted

    var id: String {
        switch self {
        case .text(let text):
            return "text-\(text.prefix(20).hashValue)"
        case .toolUse(let block):
            return "tool-\(block.id)"
        case .thinking(let text):
            return "thinking-\(text.prefix(20).hashValue)"
        case .interrupted:
            return "interrupted"
        }
    }

    /// Type prefix for generating stable IDs
    nonisolated var typePrefix: String {
        switch self {
        case .text: return "text"
        case .toolUse: return "tool"
        case .thinking: return "thinking"
        case .interrupted: return "interrupted"
        }
    }
}

struct ToolUseBlock: Equatable {
    let id: String
    let name: String
    let input: [String: String]

    /// Short preview of the tool input
    var preview: String {
        if let filePath = input["file_path"] ?? input["path"] {
            return filePath
        }
        if let command = input["command"] {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            return String(firstLine.prefix(50))
        }
        if let pattern = input["pattern"] {
            return pattern
        }
        return input.values.first.map { String($0.prefix(50)) } ?? ""
    }
}
