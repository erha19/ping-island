import XCTest
@testable import Ping_Island

@MainActor
final class KeepAwakeSettingsTests: XCTestCase {
    private static var retainedStores: [AppSettingsStore] = []

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "PingIslandTests.KeepAwakeSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private func makeStore(_ defaults: UserDefaults) -> AppSettingsStore {
        let store = AppSettingsStore(defaults: defaults, bridgeRuntimeConfigWriter: { _ in })
        Self.retainedStores.append(store)
        return store
    }

    func testNewInstallationDefaultsOff() {
        withDefaults { defaults in
            XCTAssertEqual(makeStore(defaults).keepAwakeMode, .off)
        }
    }

    func testLegacyEnabledMigratesToAutoAndRemovesLegacyKey() {
        withDefaults { defaults in
            defaults.set(true, forKey: "preventSleepWhileWorkingEnabled")
            XCTAssertEqual(makeStore(defaults).keepAwakeMode, .auto)
            XCTAssertEqual(defaults.string(forKey: "keepAwakeMode"), "auto")
            XCTAssertNil(defaults.object(forKey: "preventSleepWhileWorkingEnabled"))
            XCTAssertEqual(makeStore(defaults).keepAwakeMode, .auto)
        }
    }

    func testLegacyDisabledMigratesOff() {
        withDefaults { defaults in
            defaults.set(false, forKey: "preventSleepWhileWorkingEnabled")
            XCTAssertEqual(makeStore(defaults).keepAwakeMode, .off)
            XCTAssertNil(defaults.object(forKey: "preventSleepWhileWorkingEnabled"))
        }
    }

    func testExplicitModeTakesPrecedenceOverLegacyEnabled() {
        for mode in KeepAwakeMode.allCases {
            withDefaults { defaults in
                defaults.set(true, forKey: "preventSleepWhileWorkingEnabled")
                defaults.set(mode.rawValue, forKey: "keepAwakeMode")
                XCTAssertEqual(makeStore(defaults).keepAwakeMode, mode)
                XCTAssertNil(defaults.object(forKey: "preventSleepWhileWorkingEnabled"))
            }
        }
    }

    func testModeChangesSurviveReload() {
        withDefaults { defaults in
            let store = makeStore(defaults)
            for mode in [KeepAwakeMode.always, .auto, .off] {
                store.keepAwakeMode = mode
                XCTAssertEqual(makeStore(defaults).keepAwakeMode, mode)
            }
        }
    }
}
