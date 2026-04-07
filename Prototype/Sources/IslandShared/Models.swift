import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case copilot
}

public enum SessionStatusKind: String, Codable, CaseIterable, Sendable {
    case idle
    case active
    case thinking
    case runningTool
    case waitingForApproval
    case waitingForInput
    case compacting
    case completed
    case interrupted
    case notification
    case error
}

public struct SessionStatus: Codable, Equatable, Sendable {
    public var kind: SessionStatusKind
    public var detail: String?

    public init(kind: SessionStatusKind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    public var requiresAttention: Bool {
        switch kind {
        case .waitingForApproval, .waitingForInput, .error:
            return true
        default:
            return false
        }
    }
}

public struct TerminalContext: Codable, Equatable, Hashable, Sendable {
    public var terminalProgram: String?
    public var terminalBundleID: String?
    public var iTermSessionID: String?
    public var terminalSessionID: String?
    public var tty: String?
    public var currentDirectory: String?
    public var tmuxSession: String?
    public var tmuxPane: String?

    public init(
        terminalProgram: String? = nil,
        terminalBundleID: String? = nil,
        iTermSessionID: String? = nil,
        terminalSessionID: String? = nil,
        tty: String? = nil,
        currentDirectory: String? = nil,
        tmuxSession: String? = nil,
        tmuxPane: String? = nil
    ) {
        self.terminalProgram = terminalProgram
        self.terminalBundleID = terminalBundleID
        self.iTermSessionID = iTermSessionID
        self.terminalSessionID = terminalSessionID
        self.tty = tty
        self.currentDirectory = currentDirectory
        self.tmuxSession = tmuxSession
        self.tmuxPane = tmuxPane
    }
}

public enum InterventionKind: String, Codable, Sendable {
    case approval
    case question
}

public struct InterventionOption: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String?

    public init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public struct InterventionRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sessionID: String
    public var kind: InterventionKind
    public var title: String
    public var message: String
    public var options: [InterventionOption]
    public var rawContext: [String: String]

    public init(
        id: UUID = UUID(),
        sessionID: String,
        kind: InterventionKind,
        title: String,
        message: String,
        options: [InterventionOption] = [],
        rawContext: [String: String] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.message = message
        self.options = options
        self.rawContext = rawContext
    }
}

public enum InterventionDecision: Codable, Equatable, Sendable {
    case approve
    case approveForSession
    case deny
    case cancel
    case answer([String: String])
}

public struct AgentSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: AgentProvider
    public var title: String
    public var preview: String
    public var cwd: String?
    public var status: SessionStatus
    public var updatedAt: Date
    public var terminalContext: TerminalContext
    public var intervention: InterventionRequest?
    public var metadata: [String: String]

    public init(
        id: String,
        provider: AgentProvider,
        title: String,
        preview: String,
        cwd: String? = nil,
        status: SessionStatus,
        updatedAt: Date = .now,
        terminalContext: TerminalContext = TerminalContext(),
        intervention: InterventionRequest? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.preview = preview
        self.cwd = cwd
        self.status = status
        self.updatedAt = updatedAt
        self.terminalContext = terminalContext
        self.intervention = intervention
        self.metadata = metadata
    }
}

public struct BridgeEnvelope: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var provider: AgentProvider
    public var eventType: String
    public var sessionKey: String
    public var title: String?
    public var preview: String?
    public var cwd: String?
    public var status: SessionStatus?
    public var terminalContext: TerminalContext
    public var intervention: InterventionRequest?
    public var expectsResponse: Bool
    public var metadata: [String: String]
    public var sentAt: Date

    public init(
        id: UUID = UUID(),
        provider: AgentProvider,
        eventType: String,
        sessionKey: String,
        title: String? = nil,
        preview: String? = nil,
        cwd: String? = nil,
        status: SessionStatus? = nil,
        terminalContext: TerminalContext = TerminalContext(),
        intervention: InterventionRequest? = nil,
        expectsResponse: Bool = false,
        metadata: [String: String] = [:],
        sentAt: Date = .now
    ) {
        self.id = id
        self.provider = provider
        self.eventType = eventType
        self.sessionKey = sessionKey
        self.title = title
        self.preview = preview
        self.cwd = cwd
        self.status = status
        self.terminalContext = terminalContext
        self.intervention = intervention
        self.expectsResponse = expectsResponse
        self.metadata = metadata
        self.sentAt = sentAt
    }
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }

    public var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .string(let string):
            return string
        case .array(let array):
            return array.map(\.foundationObject)
        case .object(let object):
            return object.mapValues(\.foundationObject)
        }
    }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var decision: InterventionDecision?
    public var reason: String?
    public var updatedInput: [String: JSONValue]?
    public var errorMessage: String?

    public init(
        requestID: UUID,
        decision: InterventionDecision? = nil,
        reason: String? = nil,
        updatedInput: [String: JSONValue]? = nil,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.decision = decision
        self.reason = reason
        self.updatedInput = updatedInput
        self.errorMessage = errorMessage
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public var sessions: [AgentSession]
    public var selectedSessionID: String?
    public var isExpanded: Bool

    public init(
        sessions: [AgentSession] = [],
        selectedSessionID: String? = nil,
        isExpanded: Bool = false
    ) {
        self.sessions = sessions
        self.selectedSessionID = selectedSessionID
        self.isExpanded = isExpanded
    }

    public var highlightedIntervention: InterventionRequest? {
        sessions.first(where: { $0.intervention != nil })?.intervention
    }
}
