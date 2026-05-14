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

        store.floatingPetSizeMode = .large

        let reloadedStore = makeStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.floatingPetSizeMode, .large)
        XCTAssertEqual(
            defaults.string(forKey: AppSettingsDefaultKeys.floatingPetSizeMode),
            FloatingPetSizeMode.large.rawValue
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
