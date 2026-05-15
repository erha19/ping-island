import Foundation

public struct BridgeRuntimeConfig: Sendable, Equatable {
    public var routePromptsToTerminal: Bool

    public init(routePromptsToTerminal: Bool = false) {
        self.routePromptsToTerminal = routePromptsToTerminal
    }

    public static let `default` = BridgeRuntimeConfig()

    public static let relativeConfigPath = ".ping-island/bridge-config.json"
    public static let configPathEnvironmentKey = "PING_ISLAND_BRIDGE_CONFIG"

    public static func defaultConfigURL(home: URL? = nil) -> URL {
        let base = home ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(relativeConfigPath)
    }

    public static func configuredURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[configPathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        return defaultConfigURL()
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgeRuntimeConfig {
        load(from: configuredURL(environment: environment))
    }

    public static func load(from url: URL) -> BridgeRuntimeConfig {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .default
        }
        let route = (json["routePromptsToTerminal"] as? Bool) ?? false
        return BridgeRuntimeConfig(routePromptsToTerminal: route)
    }

    public var jsonObject: [String: Any] {
        ["routePromptsToTerminal": routePromptsToTerminal]
    }
}
