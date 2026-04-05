import Foundation

struct PersistedSessionAssociation: Codable, Equatable, Sendable {
    let provider: SessionProvider
    let sessionId: String
    var cwd: String
    var projectName: String
    var clientInfo: SessionClientInfo
    var sessionName: String?

    nonisolated init(session: SessionState) {
        self.provider = session.provider
        self.sessionId = session.sessionId
        self.cwd = session.cwd
        self.projectName = session.projectName
        self.clientInfo = session.clientInfo
        self.sessionName = session.sessionName
    }
}

enum SessionAssociationStore {
    nonisolated private static let directoryName = "ClaudeIsland"
    nonisolated private static let fileName = "session-associations.json"

    nonisolated static func cacheKey(provider: SessionProvider, sessionId: String) -> String {
        "\(provider.rawValue):\(sessionId)"
    }

    nonisolated static func load() -> [String: PersistedSessionAssociation] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return [:]
        }

        guard let associations = try? JSONDecoder().decode([String: PersistedSessionAssociation].self, from: data) else {
            return [:]
        }

        return associations
    }

    nonisolated static func save(_ associations: [String: PersistedSessionAssociation]) {
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(associations) else {
            return
        }

        try? data.write(to: fileURL, options: [.atomic])
    }

    nonisolated static var diagnosticsFileURL: URL {
        fileURL
    }

    nonisolated private static var directoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(directoryName, isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/\(directoryName)", isDirectory: true)
    }

    nonisolated private static var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }
}
