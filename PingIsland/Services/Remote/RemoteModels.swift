import Foundation

struct RemoteSSHLink: Equatable, Sendable {
    let username: String?
    let host: String
    let port: Int

    init?(sshTarget: String) {
        let trimmedTarget = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { return nil }

        let userSplit = trimmedTarget.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let username: String?
        let hostPortSegment: String

        if userSplit.count == 2 {
            let rawUsername = String(userSplit[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            username = rawUsername.isEmpty ? nil : rawUsername
            hostPortSegment = String(userSplit[1])
        } else {
            username = nil
            hostPortSegment = trimmedTarget
        }

        let parsedHostPort = Self.parseHostAndPort(hostPortSegment)
        guard let host = parsedHostPort.host else { return nil }

        self.username = username
        self.host = host
        self.port = parsedHostPort.port ?? 22
    }

    var urlString: String {
        let encodedUsername = username?
            .addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
        let hostComponent = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let userPrefix = encodedUsername.map { "\($0)@" } ?? ""
        return "ssh://\(userPrefix)\(hostComponent):\(port)"
    }

    var url: URL? {
        URL(string: urlString)
    }

    private static func parseHostAndPort(_ value: String) -> (host: String?, port: Int?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        if trimmed.hasPrefix("["),
           let closingBracketIndex = trimmed.firstIndex(of: "]") {
            let hostStart = trimmed.index(after: trimmed.startIndex)
            let host = String(trimmed[hostStart..<closingBracketIndex])
            let remainder = trimmed[trimmed.index(after: closingBracketIndex)...]
            let port = remainder.first == ":" ? Int(remainder.dropFirst()) : nil
            return (host.isEmpty ? nil : host, port)
        }

        if let colonIndex = trimmed.lastIndex(of: ":"),
           !trimmed[trimmed.index(after: colonIndex)...].isEmpty,
           let port = Int(trimmed[trimmed.index(after: colonIndex)...]),
           !trimmed[..<colonIndex].contains(":") {
            let host = String(trimmed[..<colonIndex])
            return (host.isEmpty ? nil : host, port)
        }

        return (trimmed, nil)
    }
}

enum RemoteEndpointAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case unknown
    case publicKey
    case passwordSession

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .unknown:
            return "未识别"
        case .publicKey:
            return "公钥 / SSH Agent"
        case .passwordSession:
            return "密码认证"
        }
    }
}

enum RemoteEndpointConnectionPhase: String, Codable, Equatable, Sendable {
    case disconnected
    case probing
    case bootstrapping
    case connecting
    case connected
    case degraded
    case failed

    var titleKey: String {
        switch self {
        case .disconnected:
            return "未连接"
        case .probing:
            return "检测中"
        case .bootstrapping:
            return "安装中"
        case .connecting:
            return "连接中"
        case .connected:
            return "已连接"
        case .degraded:
            return "连接不稳定"
        case .failed:
            return "失败"
        }
    }
}

struct RemoteEndpoint: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var sshTarget: String
    var authMode: RemoteEndpointAuthMode
    var detectedUsername: String?
    var detectedHostname: String?
    var detectedHomeDirectory: String?
    var hostFingerprint: String?
    var remoteInstallRoot: String
    var remoteHookSocketPath: String
    var remoteControlSocketPath: String
    var agentVersion: String?
    var lastConnectedAt: Date?
    var lastBootstrapAt: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        sshTarget: String,
        authMode: RemoteEndpointAuthMode = .unknown,
        detectedUsername: String? = nil,
        detectedHostname: String? = nil,
        detectedHomeDirectory: String? = nil,
        hostFingerprint: String? = nil,
        remoteInstallRoot: String = "~/.ping-island",
        remoteHookSocketPath: String = "~/.ping-island/run/agent-hook.sock",
        remoteControlSocketPath: String = "~/.ping-island/run/agent-control.sock",
        agentVersion: String? = nil,
        lastConnectedAt: Date? = nil,
        lastBootstrapAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sshTarget = sshTarget
        self.authMode = authMode
        self.detectedUsername = detectedUsername
        self.detectedHostname = detectedHostname
        self.detectedHomeDirectory = detectedHomeDirectory
        self.hostFingerprint = hostFingerprint
        self.remoteInstallRoot = remoteInstallRoot
        self.remoteHookSocketPath = remoteHookSocketPath
        self.remoteControlSocketPath = remoteControlSocketPath
        self.agentVersion = agentVersion
        self.lastConnectedAt = lastConnectedAt
        self.lastBootstrapAt = lastBootstrapAt
    }

    var resolvedTitle: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return sshTarget
    }

    var sshLink: RemoteSSHLink? {
        RemoteSSHLink(sshTarget: sshTarget)
    }

    var sshURL: URL? {
        sshLink?.url
    }
}

struct RemoteEndpointRuntimeState: Codable, Equatable, Sendable {
    var phase: RemoteEndpointConnectionPhase
    var detail: String
    var lastError: String?
    var requiresPassword: Bool
    var agentVersion: String?

    init(
        phase: RemoteEndpointConnectionPhase = .disconnected,
        detail: String = "尚未建立远程转发连接",
        lastError: String? = nil,
        requiresPassword: Bool = false,
        agentVersion: String? = nil
    ) {
        self.phase = phase
        self.detail = detail
        self.lastError = lastError
        self.requiresPassword = requiresPassword
        self.agentVersion = agentVersion
    }
}

struct RemoteEndpointDiagnosticsSnapshot: Codable, Sendable {
    let endpoint: RemoteEndpoint
    let runtimeState: RemoteEndpointRuntimeState
}

struct RemoteHostProbe: Sendable {
    let username: String
    let hostname: String
    let homeDirectory: String
    let operatingSystem: String
    let architecture: String
    let hasClaude: Bool
    let hasTmux: Bool
    let fingerprint: String?
}

struct RemoteHookClientInfoPayload: Codable, Sendable {
    let kind: String
    let profileID: String?
    let name: String?
    let bundleIdentifier: String?
    let launchURL: String?
    let origin: String?
    let originator: String?
    let threadSource: String?
    let transport: String?
    let remoteHost: String?
    let sessionFilePath: String?
    let terminalBundleIdentifier: String?
    let terminalProgram: String?
    let terminalSessionIdentifier: String?
    let iTermSessionIdentifier: String?
    let tmuxSessionIdentifier: String?
    let tmuxPaneIdentifier: String?
    let processName: String?
}

struct RemoteHookEventPayload: Codable, Sendable {
    let requestID: UUID
    let sessionID: String
    let cwd: String
    let event: String
    let status: String
    let provider: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: RemoteJSONValue]?
    let toolUseID: String?
    let notificationType: String?
    let message: String?
    let expectsResponse: Bool
    let clientInfo: RemoteHookClientInfoPayload
}

struct RemoteDaemonHello: Codable, Sendable {
    let type: String
    let version: String
    let hostname: String
}

struct RemoteHookEventMessage: Codable, Sendable {
    let type: String
    let payload: RemoteHookEventPayload
}

struct RemoteDecisionMessage: Encodable, Sendable {
    let type: String = "decision"
    let requestID: UUID
    let decision: String
    let reason: String?
    let updatedInput: [String: RemoteJSONValue]?
}

enum RemoteJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([RemoteJSONValue])
    case object([String: RemoteJSONValue])

    init(from decoder: Decoder) throws {
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
        } else if let array = try? container.decode([RemoteJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: RemoteJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
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

    nonisolated var foundationObject: Any {
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

    nonisolated static func fromFoundationObject(_ value: Any) -> RemoteJSONValue {
        switch value {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(value.map(Self.fromFoundationObject))
        case let value as [String: Any]:
            return .object(value.mapValues(Self.fromFoundationObject))
        default:
            return .string(String(describing: value))
        }
    }
}
