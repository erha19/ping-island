//
//  PingIslandApp.swift
//  PingIsland
//
//  Dynamic Island for monitoring AI coding sessions
//

import SwiftUI

@main
struct PingIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsWindowView()
        }
        .defaultSize(width: 648, height: 522)
    }
}
