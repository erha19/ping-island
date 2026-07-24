//
//  IslandOpenPanelPresenter.swift
//  PingIsland
//
//  Presents NSOpenPanel above Ping Island floating/notch panels.
//

import AppKit

enum IslandOpenPanelPresenter {
    /// Directory picker that stays above Ping Island floating/notch panels.
    @MainActor
    static func chooseDirectory(
        prompt: String = "Choose",
        message: String? = nil,
        startingDirectory: URL? = nil,
        showsHiddenFiles: Bool = false,
        onPresent: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.showsHiddenFiles = showsHiddenFiles
        if let message {
            panel.message = message
        }
        if let startingDirectory {
            panel.directoryURL = startingDirectory
        }

        // Island panels sit at `.mainMenu + 3`; keep the open panel above them.
        panel.level = .mainMenu + 4
        panel.collectionBehavior.insert(.moveToActiveSpace)

        onPresent?()
        let restoredLevels = temporarilyLowerIslandPanels()
        defer {
            restoreIslandPanelLevels(restoredLevels)
            onDismiss?()
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @MainActor
    private static func temporarilyLowerIslandPanels() -> [(NSWindow, NSWindow.Level)] {
        let threshold = NSWindow.Level.mainMenu.rawValue
        var saved: [(NSWindow, NSWindow.Level)] = []
        for window in NSApp.windows where window.level.rawValue >= threshold {
            saved.append((window, window.level))
            window.level = .normal
        }
        return saved
    }

    @MainActor
    private static func restoreIslandPanelLevels(_ saved: [(NSWindow, NSWindow.Level)]) {
        for (window, level) in saved {
            window.level = level
        }
    }
}
