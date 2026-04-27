import Foundation

struct CompanionRelayEvent: Identifiable, Codable, Equatable {
    let id: String
    let kind: String
    let sessionID: String
    let title: String
    let body: String
    let clientName: String
    let payload: [String: String]
    let createdAt: Date
}

struct CompanionPermissionResponse: Codable, Equatable {
    let sessionID: String
    let toolUseID: String?
    let decision: String
    let text: String?
}

@MainActor
final class CompanionRelayStore: ObservableObject {
    @Published var serverURLString = "http://127.0.0.1:8787"
    @Published var pairingCode = ""
    @Published var events: [CompanionRelayEvent] = []
    @Published var status = "Not connected"

    func pair() async {
        guard let url = URL(string: serverURLString)?.appendingPathComponent("v1/pair") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": pairingCode,
            "name": Host.current().localizedName ?? "Companion",
            "platform": "iOS"
        ])

        do {
            _ = try await URLSession.shared.data(for: request)
            status = "Paired"
        } catch {
            status = error.localizedDescription
        }
    }

    func send(decision: CompanionPermissionResponse) async {
        guard let url = URL(string: serverURLString)?.appendingPathComponent("v1/responses") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(decision)
        _ = try? await URLSession.shared.data(for: request)
    }
}
