import SwiftUI

@main
struct PingIslandCompanionApp: App {
    @StateObject private var relayStore = CompanionRelayStore()

    var body: some Scene {
        WindowGroup {
            CompanionContentView()
                .environmentObject(relayStore)
        }
    }
}
