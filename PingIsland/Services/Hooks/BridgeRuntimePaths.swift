import Foundation

enum BridgeRuntimePaths {
    static let appGroupIdentifier = "group.com.wudanwu.PingIsland"
    static let legacySocketPath = "/tmp/island.sock"
    static let bridgeConfigEnvironmentKey = "PING_ISLAND_BRIDGE_CONFIG"
    static let socketPathEnvironmentKey = "ISLAND_SOCKET_PATH"

    private static let legacyConfigRelativePath = ".ping-island/bridge-config.json"

    static var socketPath: String {
#if APP_STORE
        runtimeDirectoryURL.appendingPathComponent("i.sock").path
#else
        legacySocketPath
#endif
    }

    static var runtimeConfigURL: URL {
#if APP_STORE
        runtimeDirectoryURL.appendingPathComponent("c.json")
#else
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(legacyConfigRelativePath)
#endif
    }

    static var runtimeDirectoryURL: URL {
#if APP_STORE
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return containerURL.appendingPathComponent("b", isDirectory: true)
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ping-island", isDirectory: true)
    }

    static func prepareRuntimeDirectory() {
        try? FileManager.default.createDirectory(
            at: runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    static var launcherEnvironment: [String: String] {
        [
            socketPathEnvironmentKey: socketPath,
            bridgeConfigEnvironmentKey: runtimeConfigURL.path
        ]
    }
}
