import Combine
import Foundation

struct IslandRelayPairingCode: Codable, Equatable, Sendable {
    let code: String
    let expiresAt: Date

    static func generate(now: Date = Date()) -> IslandRelayPairingCode {
        let number = Int.random(in: 100_000...999_999)
        return IslandRelayPairingCode(
            code: String(number),
            expiresAt: now.addingTimeInterval(10 * 60)
        )
    }
}

struct IslandRelayDevice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var platform: String
    var lastSeenAt: Date
}

enum IslandRelayMessageKind: String, Codable, Equatable, Sendable {
    case session
    case permission
    case question
    case completion
    case permissionResponse
    case textReply
}

struct IslandRelayMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: IslandRelayMessageKind
    let sessionID: String
    let title: String
    let body: String
    let clientName: String
    let payload: [String: String]
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        kind: IslandRelayMessageKind,
        sessionID: String,
        title: String,
        body: String,
        clientName: String,
        payload: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.title = title
        self.body = body
        self.clientName = clientName
        self.payload = payload
        self.createdAt = createdAt
    }
}

struct IslandRelayPermissionResponse: Codable, Equatable, Sendable {
    enum Decision: String, Codable, Equatable, Sendable {
        case allow
        case deny
    }

    let sessionID: String
    let toolUseID: String?
    let decision: Decision
    let text: String?
}

@MainActor
final class IslandRelayClient: ObservableObject {
    static let shared = IslandRelayClient()

    @Published private(set) var pairingCode: IslandRelayPairingCode
    @Published private(set) var devices: [IslandRelayDevice]
    @Published private(set) var outbox: [IslandRelayMessage]
    @Published private(set) var lastDeliveryStatus: String?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let pairingCode = "IslandRelayClient.pairingCode.v1"
        static let devices = "IslandRelayClient.devices.v1"
        static let outbox = "IslandRelayClient.outbox.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        if let data = defaults.data(forKey: Keys.pairingCode),
           let decoded = try? decoder.decode(IslandRelayPairingCode.self, from: data),
           decoded.expiresAt > Date() {
            pairingCode = decoded
        } else {
            pairingCode = IslandRelayPairingCode.generate()
        }

        devices = Self.decode([IslandRelayDevice].self, from: defaults, key: Keys.devices, decoder: decoder) ?? []
        outbox = Self.decode([IslandRelayMessage].self, from: defaults, key: Keys.outbox, decoder: decoder) ?? []
        persistPairingCode()
    }

    func rotatePairingCode() {
        pairingCode = IslandRelayPairingCode.generate()
        persistPairingCode()
    }

    func registerDevice(name: String, platform: String, id: String = UUID().uuidString) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = IslandRelayDevice(
            id: id,
            name: trimmedName.isEmpty ? "Companion" : trimmedName,
            platform: platform,
            lastSeenAt: Date()
        )
        devices.removeAll { $0.id == id }
        devices.insert(device, at: 0)
        persistDevices()
    }

    func removeDevice(id: String) {
        devices.removeAll { $0.id == id }
        persistDevices()
    }

    func enqueueAttention(for session: SessionState) {
        let kind: IslandRelayMessageKind
        if session.needsApprovalResponse {
            kind = .permission
        } else if session.needsQuestionResponse {
            kind = .question
        } else if session.phase == .ended {
            kind = .completion
        } else {
            kind = .session
        }

        enqueue(
            IslandRelayMessage(
                kind: kind,
                sessionID: session.sessionId,
                title: session.displayTitle,
                body: session.intervention?.summaryText
                    ?? session.pendingToolName
                    ?? session.previewText
                    ?? session.latestHookMessage
                    ?? session.projectName,
                clientName: session.clientDisplayName,
                payload: [
                    "cwd": session.cwd,
                    "project": session.projectName,
                    "provider": session.provider.rawValue,
                    "tool": session.pendingToolName ?? ""
                ].filter { !$0.value.isEmpty }
            )
        )
    }

    func enqueue(_ message: IslandRelayMessage) {
        outbox.insert(message, at: 0)
        outbox = Array(outbox.prefix(50))
        persistOutbox()
        guard AppSettings.relayEnabled else {
            lastDeliveryStatus = "Relay disabled; message queued locally."
            return
        }

        let serverURLString = AppSettings.relayServerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = URL(string: serverURLString), !serverURLString.isEmpty else {
            lastDeliveryStatus = "Relay URL is empty; message queued locally."
            return
        }

        Task {
            do {
                try await Self.post(message, to: serverURL)
                await MainActor.run {
                    lastDeliveryStatus = "Delivered \(message.kind.rawValue) to relay."
                }
            } catch {
                await MainActor.run {
                    lastDeliveryStatus = "Relay delivery failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func clearOutbox() {
        outbox = []
        persistOutbox()
    }

    private static func post(_ message: IslandRelayMessage, to serverURL: URL) async throws {
        let eventsURL = serverURL.appendingPathComponent("v1/events")
        var request = URLRequest(url: eventsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(message)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func persistPairingCode() {
        persist(pairingCode, key: Keys.pairingCode)
    }

    private func persistDevices() {
        persist(devices, key: Keys.devices)
    }

    private func persistOutbox() {
        persist(outbox, key: Keys.outbox)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from defaults: UserDefaults,
        key: String,
        decoder: JSONDecoder
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
