import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private let launchConfiguration = AppLaunchConfiguration()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if launchConfiguration.shouldEnforceSingleInstance && !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        if !launchConfiguration.isRunningTests {
            UpdateManager.shared.start()
        }

        if launchConfiguration.shouldInstallIntegrations {
            HookInstaller.installIfNeeded()
            IDEExtensionInstaller.cleanupLegacyTraeExtension()
        }

        NSApplication.shared.setActivationPolicy(launchConfiguration.activationPolicy)

        if launchConfiguration.shouldCreateNotchWindow {
            windowManager = WindowManager()
            _ = windowManager?.setupNotchWindow()
        }

        if launchConfiguration.shouldObserveScreens {
            screenObserver = ScreenObserver { [weak self] in
                self?.handleScreenChange()
            }
        }

        if launchConfiguration.shouldPresentSettingsWindowOnLaunch {
            SettingsWindowController.shared.present()
        }
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenObserver = nil
    }
    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.wudanwu.PingIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
