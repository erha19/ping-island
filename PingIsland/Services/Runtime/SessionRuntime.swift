//
//  SessionRuntime.swift
//  PingIsland
//
//  Provider-agnostic native runtime protocol.
//

import Foundation

struct SessionRuntimeLaunchRequest: Sendable {
    let provider: SessionProvider
    let cwd: String
    let resumeSessionID: String?
    let preferredSessionID: String?
    let metadata: [String: String]

    init(
        provider: SessionProvider,
        cwd: String,
        resumeSessionID: String? = nil,
        preferredSessionID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.provider = provider
        self.cwd = cwd
        self.resumeSessionID = resumeSessionID
        self.preferredSessionID = preferredSessionID
        self.metadata = metadata
    }
}

struct SessionRuntimeHandle: Codable, Equatable, Sendable {
    let sessionID: String
    let provider: SessionProvider
    let cwd: String
    let createdAt: Date
    let resumeToken: String?
    let runtimeIdentifier: String
    let sessionFilePath: String?
}

enum SessionRuntimeStopReason: String, Codable, Equatable, Sendable {
    case finished
    case cancelled
    case crashed
    case unavailable
}

enum SessionRuntimeEvent: Sendable {
    case started(SessionRuntimeHandle)
    case stopped(sessionID: String, reason: SessionRuntimeStopReason)
    case availabilityChanged(Bool)
}

enum SessionRuntimeError: LocalizedError, Equatable, Sendable {
    case unsupportedProvider(SessionProvider)
    case runtimeDisabled(SessionProvider)
    case runtimeUnavailable(SessionProvider)
    case sessionNotFound(String)
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return "Provider \(provider.rawValue) is not supported by the native runtime."
        case .runtimeDisabled(let provider):
            return "Native runtime for \(provider.rawValue) is disabled."
        case .runtimeUnavailable(let provider):
            return "Native runtime for \(provider.rawValue) is unavailable on this machine."
        case .sessionNotFound(let sessionID):
            return "Native runtime session \(sessionID) could not be found."
        case .unsupportedOperation(let operation):
            return "Operation \(operation) is not implemented by this runtime yet."
        }
    }
}

protocol SessionRuntime: Sendable {
    var provider: SessionProvider { get }
    var events: AsyncStream<SessionRuntimeEvent> { get }

    func prepare() async
    func shutdown() async
    func isAvailable() async -> Bool
    func startSession(_ request: SessionRuntimeLaunchRequest) async throws -> SessionRuntimeHandle
    func resumeSession(id: String) async throws -> SessionRuntimeHandle
    func terminateSession(id: String) async throws
    func sendUserInput(sessionId: String, text: String) async throws
    func approve(sessionId: String, forSession: Bool) async throws
    func deny(sessionId: String, reason: String?) async throws
    func answer(sessionId: String, answers: [String: [String]]) async throws
    func continueSession(sessionId: String, expectedTurnId: String?, text: String) async throws
}

extension SessionRuntime {
    func sendUserInput(sessionId: String, text: String) async throws {
        throw SessionRuntimeError.unsupportedOperation("sendUserInput")
    }

    func approve(sessionId: String, forSession: Bool) async throws {
        throw SessionRuntimeError.unsupportedOperation("approve")
    }

    func deny(sessionId: String, reason: String?) async throws {
        throw SessionRuntimeError.unsupportedOperation("deny")
    }

    func answer(sessionId: String, answers: [String: [String]]) async throws {
        throw SessionRuntimeError.unsupportedOperation("answer")
    }

    func continueSession(sessionId: String, expectedTurnId: String?, text: String) async throws {
        try await sendUserInput(sessionId: sessionId, text: text)
    }
}
