import Foundation

/// Writes the small runtime config consumed by `PingIslandBridge` at hook time.
/// Schema must stay in sync with `BridgeRuntimeConfig` in `IslandShared`.
enum BridgeRuntimeConfigWriter {
    static func write(routePromptsToTerminal: Bool) {
        let url = BridgeRuntimePaths.runtimeConfigURL
        let payload: [String: Any] = [
            "routePromptsToTerminal": routePromptsToTerminal
        ]

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        try? data.write(to: url, options: .atomic)
    }
}
