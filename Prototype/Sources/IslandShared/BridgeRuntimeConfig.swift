import Foundation

public struct BridgeRuntimeConfig: Sendable, Equatable {
    public var routePromptsToTerminal: Bool

    public init(routePromptsToTerminal: Bool = false) {
        self.routePromptsToTerminal = routePromptsToTerminal
    }

    public static let `default` = BridgeRuntimeConfig()

    public static let relativeConfigPath = ".ping-island/bridge-config.json"

    public static func defaultConfigURL(home: URL? = nil) -> URL {
        let base = home ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(relativeConfigPath)
    }

    public static func load(from url: URL = defaultConfigURL()) -> BridgeRuntimeConfig {
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
