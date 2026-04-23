import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private let launchConfiguration = AppLaunchConfiguration()
    private let startupSessionMonitor = SessionMonitor()
    private let globalShortcutManager = GlobalShortcutManager.shared
    private var shouldPresentSettingsAfterOnboarding = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if launchConfiguration.shouldEnforceSingleInstance && !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        if !launchConfiguration.isRunningTests {
            UpdateManager.shared.start()
        }

        if launchConfiguration.shouldInstallIntegrations {
            HookInstaller.installIfNeeded(
                markPresentationOnboardingPending: {
                    AppSettings.presentationModeOnboardingPending = true
                }
            )
            IDEExtensionInstaller.cleanupLegacyTraeExtension()
            NotchDetachmentHintExperience.prepareForLaunch(
                previousVersion: HookInstaller.getVersionMetadata()?["previousVersion"] as? String,
                markHintsPending: {
                    AppSettings.notchDetachmentHintPending = true
                    AppSettings.floatingPetSettingsHintPending = true
                }
            )
        }

        NSApplication.shared.setActivationPolicy(launchConfiguration.activationPolicy)

        let launchFlow = AppLaunchFlow(
            configuration: launchConfiguration,
            presentationModeOnboardingPending: AppSettings.presentationModeOnboardingPending
        )
        shouldPresentSettingsAfterOnboarding = launchFlow.shouldPresentSettingsWindowAfterOnboarding

        if launchFlow.shouldStartMonitoringImmediately {
            // Keep hook and app-server ingestion alive even when first-run onboarding
            // defers the initial Island window.
            startupSessionMonitor.startMonitoring()
        }

        if launchFlow.shouldCreateInitialIslandWindow {
            startWindowManagerIfNeeded()
        }

        if launchConfiguration.shouldObserveScreens {
            screenObserver = ScreenObserver { [weak self] in
                self?.handleScreenChange()
            }
        }

        globalShortcutManager.start()

        if launchFlow.shouldPresentSurfaceModeOnboarding {
            PresentationModeWelcomeWindowController.shared.present { [weak self] selectedMode in
                self?.completePresentationModeOnboarding(with: selectedMode)
            }
        } else if launchFlow.shouldPresentSettingsWindowImmediately {
            SettingsWindowController.shared.present()
        }
        
        // Play the fixed client startup sound for the bundled 8-bit theme.
        Task { @MainActor in
            AppSettings.playClientStartupSound()
        }
    }

    @MainActor
    private func handleScreenChange() {
        guard !AppSettings.presentationModeOnboardingPending else { return }
        startWindowManagerIfNeeded()
    }

    @MainActor
    private func completePresentationModeOnboarding(with selectedMode: IslandSurfaceMode) {
        AppSettings.surfaceMode = selectedMode
        AppSettings.presentationModeOnboardingPending = false
        AppSettings.notchDetachmentHintPending = selectedMode == .notch
        startWindowManagerIfNeeded()

        if shouldPresentSettingsAfterOnboarding {
            SettingsWindowController.shared.present()
            shouldPresentSettingsAfterOnboarding = false
        }
    }

    @MainActor
    private func startWindowManagerIfNeeded() {
        if windowManager == nil {
            windowManager = WindowManager()
        }
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenObserver = nil
        startupSessionMonitor.stopMonitoring()
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
