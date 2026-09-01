import AppKit
import XCTest
@testable import Ping_Island

@MainActor
final class AppSettingsPersistenceTests: XCTestCase {
    private static var retainedStores: [AppSettingsStore] = []

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "PingIslandTests.AppSettingsPersistence.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> AppSettingsStore {
        let store = AppSettingsStore(defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }

    private func makeStore(
        defaults: UserDefaults,
        bridgeRuntimeConfigWriter: @escaping (BridgeRuntimeConfigSnapshot) -> Void
    ) -> AppSettingsStore {
        let store = AppSettingsStore(
            defaults: defaults,
            bridgeRuntimeConfigWriter: bridgeRuntimeConfigWriter
        )
        Self.retainedStores.append(store)
        return store
    }

    func testShortcutsUseDefaultsWhenNoPreferenceExists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.shortcut(for: .openActiveSession), GlobalShortcutAction.openActiveSession.defaultShortcut)
        XCTAssertEqual(store.shortcut(for: .openSessionList), GlobalShortcutAction.openSessionList.defaultShortcut)
    }

    func testClearedShortcutPersistsAsDisabledInsteadOfRestoringDefault() {
        let defaults = makeDefaults()
        let key = "openActiveSessionShortcut"
        let disabledKey = "openActiveSessionShortcutDisabled"
        let store = makeStore(defaults: defaults)

        store.setShortcut(nil, for: .openActiveSession)

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertNil(reloadedStore.shortcut(for: .openActiveSession))
        XCTAssertEqual(defaults.object(forKey: disabledKey) as? Bool, true)
        XCTAssertNil(defaults.data(forKey: key))
    }

    func testSettingShortcutAfterClearReEnablesAndPersistsCustomValue() {
        let defaults = makeDefaults()
        let disabledKey = "openSessionListShortcutDisabled"
        let store = makeStore(defaults: defaults)
        let shortcut = GlobalShortcut(
            keyCode: 45,
            modifierFlags: [.control, .option]
        )

        store.setShortcut(nil, for: .openSessionList)
        store.setShortcut(shortcut, for: .openSessionList)

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.shortcut(for: .openSessionList), shortcut)
        XCTAssertEqual(defaults.object(forKey: disabledKey) as? Bool, false)
    }

    func testShortcutLegacyDictionaryMigratesToDataStorage() {
        let defaults = makeDefaults()
        let key = "openActiveSessionShortcut"
        let modifiers: NSEvent.ModifierFlags = [.control, .option]
        let expected = GlobalShortcut(
            keyCode: 42,
            modifierFlags: modifiers
        )

        defaults.set(
            [
                "keyCode": 42,
                "modifierFlags": Int(modifiers.rawValue)
            ],
            forKey: key
        )

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.shortcut(for: .openActiveSession), expected)
        XCTAssertNotNil(defaults.data(forKey: key))
        XCTAssertNil(defaults.dictionary(forKey: key))
    }

    func testMascotOverridesLegacyDictionaryMigratesToDataStorage() {
        let defaults = makeDefaults()
        let key = "mascotOverrides"

        defaults.set(
            [
                MascotClient.codex.rawValue: MascotKind.qoder.rawValue
            ],
            forKey: key
        )

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.mascotOverride(for: .codex), .qoder)
        XCTAssertNotNil(defaults.data(forKey: key))
        XCTAssertNil(defaults.dictionary(forKey: key))
    }

    func testShortcutWritesTypedDataForFreshValues() {
        let defaults = makeDefaults()
        let key = "openSessionListShortcut"
        let store = makeStore(defaults: defaults)
        let shortcut = GlobalShortcut(
            keyCode: 44,
            modifierFlags: [.command, .shift]
        )

        store.setShortcut(shortcut, for: .openSessionList)
        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.shortcut(for: .openSessionList), shortcut)
        XCTAssertNotNil(defaults.data(forKey: key))
        XCTAssertNil(defaults.dictionary(forKey: key))
    }

    func testSubagentVisibilityModePersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.subagentVisibilityMode, .visible)

        store.subagentVisibilityMode = .visible
        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.subagentVisibilityMode, .visible)
        XCTAssertEqual(defaults.string(forKey: "subagentVisibilityMode"), SubagentVisibilityMode.visible.rawValue)
        XCTAssertEqual(defaults.string(forKey: "codexSubagentVisibilityMode"), SubagentVisibilityMode.visible.rawValue)
    }

    func testSubagentVisibilityModeFallsBackToLegacyCodexKey() {
        let defaults = makeDefaults()
        defaults.set(SubagentVisibilityMode.hidden.rawValue, forKey: "codexSubagentVisibilityMode")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.subagentVisibilityMode, .hidden)
        XCTAssertEqual(defaults.string(forKey: "subagentVisibilityMode"), SubagentVisibilityMode.hidden.rawValue)
    }

    func testSubagentVisibilityModeMigratesLegacyAllValueToVisible() {
        let defaults = makeDefaults()
        defaults.set("all", forKey: "subagentVisibilityMode")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.subagentVisibilityMode, .visible)
    }

    func testAutoOpenCompactedNotificationPanelPersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertTrue(store.autoOpenCompactedNotificationPanel)

        store.autoOpenCompactedNotificationPanel = false
        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.autoOpenCompactedNotificationPanel)
        XCTAssertEqual(defaults.object(forKey: "autoOpenCompactedNotificationPanel") as? Bool, false)
    }

    func testAutomaticUpdateChecksEnabledPersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertTrue(store.automaticUpdateChecksEnabled)

        store.automaticUpdateChecksEnabled = false

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.automaticUpdateChecksEnabled)
        XCTAssertEqual(defaults.object(forKey: "automaticUpdateChecksEnabled") as? Bool, false)
    }

    func testAnalyticsEnabledDefaultsOffAndPersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertFalse(store.analyticsEnabled)
        XCTAssertFalse(store.analyticsConsentPromptCompleted)

        store.analyticsEnabled = true
        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertTrue(reloadedStore.analyticsEnabled)
        XCTAssertTrue(reloadedStore.analyticsConsentPromptCompleted)
        XCTAssertEqual(defaults.object(forKey: "analyticsEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "analyticsConsentPromptCompleted") as? Bool, true)
    }

    func testAnalyticsConsentPromptCompletionPersistsWithoutEnablingTelemetry() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.analyticsConsentPromptCompleted = true

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.analyticsEnabled)
        XCTAssertTrue(reloadedStore.analyticsConsentPromptCompleted)
        XCTAssertNil(defaults.object(forKey: "analyticsEnabled"))
        XCTAssertEqual(defaults.object(forKey: "analyticsConsentPromptCompleted") as? Bool, true)
    }

    func testHookDebugLogSettingsPersistAndWriteRuntimeConfig() {
        let defaults = makeDefaults()
        var snapshots: [BridgeRuntimeConfigSnapshot] = []
        let store = makeStore(defaults: defaults) { snapshot in
            snapshots.append(snapshot)
        }

        XCTAssertEqual(snapshots.last?.debugLoggingEnabled, true)
        XCTAssertEqual(snapshots.last?.debugLogRetentionDays, 7)
        XCTAssertEqual(snapshots.last?.debugLogMaxDirectoryMegabytes, 256)

        store.hookDebugLoggingEnabled = false
        store.hookDebugLogRetentionDays = 14
        store.hookDebugLogMaxDirectoryMegabytes = 128

        let reloadedStore = makeStore(defaults: defaults) { snapshot in
            snapshots.append(snapshot)
        }

        XCTAssertFalse(reloadedStore.hookDebugLoggingEnabled)
        XCTAssertEqual(reloadedStore.hookDebugLogRetentionDays, 14)
        XCTAssertEqual(reloadedStore.hookDebugLogMaxDirectoryMegabytes, 128)
        XCTAssertEqual(defaults.object(forKey: "hookDebugLoggingEnabled") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "hookDebugLogRetentionDays") as? Int, 14)
        XCTAssertEqual(defaults.object(forKey: "hookDebugLogMaxDirectoryMegabytes") as? Int, 128)
        XCTAssertEqual(snapshots.last?.routePromptsToTerminal, false)
        XCTAssertEqual(snapshots.last?.debugLoggingEnabled, false)
        XCTAssertEqual(snapshots.last?.debugLogRetentionDays, 14)
        XCTAssertEqual(snapshots.last?.debugLogMaxDirectoryMegabytes, 128)
    }

    func testHookDebugLogSettingsClampOutOfRangeValues() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.hookDebugLogRetentionDays = 500
        store.hookDebugLogMaxDirectoryMegabytes = 2

        XCTAssertEqual(
            store.hookDebugLogRetentionDays,
            BridgeRuntimeConfigSnapshot.maximumDebugLogRetentionDays
        )
        XCTAssertEqual(
            store.hookDebugLogMaxDirectoryMegabytes,
            BridgeRuntimeConfigSnapshot.minimumDebugLogMaxDirectoryMegabytes
        )
    }

    func testBridgeRuntimeConfigWriterIncludesHookDebugLogSettings() throws {
        let snapshot = BridgeRuntimeConfigSnapshot(
            routePromptsToTerminal: true,
            debugLoggingEnabled: false,
            debugLogRetentionDays: 10,
            debugLogMaxDirectoryMegabytes: 64
        )

        let data = try XCTUnwrap(BridgeRuntimeConfigWriter.payloadData(snapshot))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["routePromptsToTerminal"] as? Bool, true)
        XCTAssertEqual(json["debugLoggingEnabled"] as? Bool, false)
        XCTAssertEqual(json["debugLogRetentionDays"] as? Int, 10)
        XCTAssertEqual(json["debugLogMaxDirectoryMegabytes"] as? Int, 64)
    }

    func testUsageVisibilityPersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertTrue(store.showUsage)

        store.showUsage = false
        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.showUsage)
        XCTAssertEqual(defaults.object(forKey: "showUsage") as? Bool, false)
    }

    func testUsageValueModePersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.usageValueMode, .remaining)

        store.usageValueMode = .remaining
        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.usageValueMode, .remaining)
        XCTAssertEqual(defaults.string(forKey: "usageValueMode"), UsageValueMode.remaining.rawValue)
    }

    func testClosedNotchTrailingContentModePersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.closedNotchTrailingContentMode, .sessionCount)

        store.closedNotchTrailingContentMode = .codexSevenDayRemaining
        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.closedNotchTrailingContentMode, .codexSevenDayRemaining)
        XCTAssertEqual(
            defaults.string(forKey: "closedNotchTrailingContentMode"),
            ClosedNotchTrailingContentMode.codexSevenDayRemaining.rawValue
        )
    }

    func testNotchModuleWidthDefaultsClampsAndPersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.notchModuleWidth, AppSettingsStore.defaultNotchModuleWidth)

        store.notchModuleWidth = AppSettingsStore.minimumNotchModuleWidth - 20
        XCTAssertEqual(store.notchModuleWidth, AppSettingsStore.minimumNotchModuleWidth)

        store.notchModuleWidth = 332
        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.notchModuleWidth, 332)
        XCTAssertEqual(defaults.double(forKey: AppSettingsDefaultKeys.notchModuleWidth), 332)
    }

    func testSurfaceModePersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.surfaceMode = .floatingPet

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.surfaceMode, .floatingPet)
        XCTAssertEqual(defaults.string(forKey: AppSettingsDefaultKeys.surfaceMode), IslandSurfaceMode.floatingPet.rawValue)
    }

    func testFloatingPetSizeModePersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.floatingPetSizeMode, .automatic)

        store.floatingPetSizeMode = .extraLarge

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.floatingPetSizeMode, .extraLarge)
        XCTAssertEqual(
            defaults.string(forKey: AppSettingsDefaultKeys.floatingPetSizeMode),
            FloatingPetSizeMode.extraLarge.rawValue
        )
    }

    func testPreviewMascotKindPersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.previewMascotKind = .codex

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.previewMascotKind, .codex)
        XCTAssertEqual(defaults.string(forKey: "previewMascotKind"), MascotKind.codex.rawValue)
    }

    func testOptionalMascotClientFallsBackToPreviewMascotKind() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        let client: MascotClient? = nil

        store.previewMascotKind = .qwen

        XCTAssertEqual(store.mascotKind(for: client), .qwen)
    }

    func testFloatingPetAnchorPersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        let anchor = FloatingPetAnchor(xRatio: 0.82, yRatio: 0.14)

        store.floatingPetAnchor = anchor

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.floatingPetAnchor, anchor)
        XCTAssertNotNil(defaults.data(forKey: AppSettingsDefaultKeys.floatingPetAnchor))
    }

    func testPresentationModeOnboardingPendingPersistsAndClears() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.presentationModeOnboardingPending = true
        XCTAssertEqual(defaults.object(forKey: AppSettingsDefaultKeys.presentationModeOnboardingPending) as? Bool, true)

        store.presentationModeOnboardingPending = false

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.presentationModeOnboardingPending)
        XCTAssertEqual(defaults.object(forKey: AppSettingsDefaultKeys.presentationModeOnboardingPending) as? Bool, false)
    }

    func testNotchDetachmentHintPendingPersistsAndClears() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.notchDetachmentHintPending = true
        XCTAssertEqual(defaults.object(forKey: AppSettingsDefaultKeys.notchDetachmentHintPending) as? Bool, true)

        store.notchDetachmentHintPending = false

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.notchDetachmentHintPending)
        XCTAssertEqual(defaults.object(forKey: AppSettingsDefaultKeys.notchDetachmentHintPending) as? Bool, false)
    }

    func testFloatingPetSettingsHintPendingPersistsAndClears() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        store.floatingPetSettingsHintPending = true
        XCTAssertEqual(defaults.object(forKey: AppSettingsDefaultKeys.floatingPetSettingsHintPending) as? Bool, true)

        store.floatingPetSettingsHintPending = false

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.floatingPetSettingsHintPending)
        XCTAssertEqual(defaults.object(forKey: AppSettingsDefaultKeys.floatingPetSettingsHintPending) as? Bool, false)
    }

    func testLabsSettingsUnlockedDefaultsHiddenAndPersists() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)

        XCTAssertFalse(store.labsSettingsUnlocked)

        store.labsSettingsUnlocked = true

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertTrue(reloadedStore.labsSettingsUnlocked)
        XCTAssertEqual(defaults.object(forKey: "labsSettingsUnlocked") as? Bool, true)
    }
}
