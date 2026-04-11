//
//  RuntimeSessionRegistry.swift
//  PingIsland
//
//  Persistent registry for native runtime sessions.
//

import Foundation

struct RuntimeSessionRecord: Codable, Equatable, Sendable {
    let sessionID: String
    let provider: SessionProvider
    let cwd: String
    let createdAt: Date
    var updatedAt: Date
    let resumeToken: String?
    let runtimeIdentifier: String

    nonisolated init(handle: SessionRuntimeHandle, updatedAt: Date = Date()) {
        self.sessionID = handle.sessionID
        self.provider = handle.provider
        self.cwd = handle.cwd
        self.createdAt = handle.createdAt
        self.updatedAt = updatedAt
        self.resumeToken = handle.resumeToken
        self.runtimeIdentifier = handle.runtimeIdentifier
    }
}

actor RuntimeSessionRegistry {
    static let shared = RuntimeSessionRegistry()

    private let fileURL: URL
    private var didLoad = false
    private var records: [String: RuntimeSessionRecord] = [:]

    init(fileURL: URL = RuntimeSupportPaths.sessionsFileURL) {
        self.fileURL = fileURL
    }

    func allRecords() -> [String: RuntimeSessionRecord] {
        loadIfNeeded()
        return records
    }

    func record(for sessionID: String) -> RuntimeSessionRecord? {
        loadIfNeeded()
        return records[sessionID]
    }

    func upsert(handle: SessionRuntimeHandle, updatedAt: Date = Date()) {
        loadIfNeeded()
        records[handle.sessionID] = RuntimeSessionRecord(handle: handle, updatedAt: updatedAt)
        save()
    }

    func remove(sessionID: String) {
        loadIfNeeded()
        records.removeValue(forKey: sessionID)
        save()
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: RuntimeSessionRecord].self, from: data) else {
            records = [:]
            return
        }

        records = decoded
    }

    private func save() {
        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
