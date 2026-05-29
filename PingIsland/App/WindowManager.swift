//
//  WindowManager.swift
//  PingIsland
//
//  Manages the notch window lifecycle
//

import AppKit
import Combine
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Window")

@MainActor
class WindowManager {
    private(set) var presentationCoordinator: IslandPresentationCoordinator?
    private var activeScreenNumber: NSNumber?
    private var cancellables = Set<AnyCancellable>()
    private var lastMigrationTime: Date = .distantPast

    init() {
        startFocusTracking()
    }

    /// Set up or recreate the notch window
    func setupNotchWindow() -> NotchWindowController? {
        // Use ScreenSelector for screen selection
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return nil
        }

        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let presentationCoordinator,
           activeScreenNumber == screenNumber {
            presentationCoordinator.updateScreen(screen)
            return nil
        }

        presentationCoordinator?.invalidate()
        let presentationCoordinator = IslandPresentationCoordinator(screen: screen)
        self.presentationCoordinator = presentationCoordinator
        activeScreenNumber = screenNumber
        return nil
    }

    // MARK: - Focus-based screen migration

    /// Track application focus changes. When the user activates an app on a
    /// different screen, migrate the notch to follow.
    private func startFocusTracking() {
        // Track app-level focus changes
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.handleFocusChange()
            }
            .store(in: &cancellables)

        // Track window-level focus changes (covers same-app window switches)
        NotificationCenter.default
            .publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in
                self?.handleFocusChange()
            }
            .store(in: &cancellables)
    }

    private func handleFocusChange() {
        let selector = ScreenSelector.shared
        guard selector.selectionMode == .automatic else { return }

        // Debounce
        let now = Date()
        guard now.timeIntervalSince(lastMigrationTime) > 1.0 else { return }

        // Determine target screen from cursor position
        guard let targetScreen = selector.screenContaining(NSEvent.mouseLocation),
              let currentScreen = selector.selectedScreen else { return }

        let targetID = selector.screenID(of: targetScreen)
        let currentID = selector.screenID(of: currentScreen)

        guard targetID != currentID else { return }

        lastMigrationTime = now
        logger.info("Focus changed, migrating notch to cursor screen")
        selector.migrateToScreen(targetScreen)
        _ = setupNotchWindow()
    }
}
