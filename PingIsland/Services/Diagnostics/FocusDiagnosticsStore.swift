import Foundation

actor FocusDiagnosticsStore {
    static let shared = FocusDiagnosticsStore()

    nonisolated static var diagnosticsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ping-island-debug", isDirectory: true)
            .appendingPathComponent("focus-debug.log")
    }

    private let fileManager = FileManager.default
    private let encoder = ISO8601DateFormatter()

    private init() {}

    func record(_ message: String) {
        let line = "[\(encoder.string(from: Date()))] \(message)\n"
        let url = Self.diagnosticsFileURL

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if !fileManager.fileExists(atPath: url.path) {
                try Data(line.utf8).write(to: url, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Avoid surfacing diagnostics write failures into the main focus path.
        }
    }
}
