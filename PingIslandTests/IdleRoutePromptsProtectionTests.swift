import XCTest
@testable import NotchCode

final class IdleRoutePromptsProtectionTests: XCTestCase {
    func testIdleProtectionDefaultsToEnabledAtThirtyMinutes() async {
        await MainActor.run {
            let settings = makeSettings()

            XCTAssertTrue(settings.autoRoutePromptsToTerminalWhenIdleEnabled)
            XCTAssertEqual(settings.autoRoutePromptsIdleDelay, .thirtyMinutes)
            XCTAssertFalse(settings.routePromptsToTerminal)
            XCTAssertFalse(settings.effectiveRoutePromptsToTerminal)
        }
    }

    func testIdleProtectionThresholds() {
        for delay in AutoRoutePromptsIdleDelay.allCases {
            XCTAssertFalse(UserIdleAutoProtection.shouldActivateAutoProtection(
                enabled: true,
                delay: delay,
                idleSeconds: delay.duration - 1
            ))
            XCTAssertTrue(UserIdleAutoProtection.shouldActivateAutoProtection(
                enabled: true,
                delay: delay,
                idleSeconds: delay.duration
            ))
        }

        XCTAssertFalse(UserIdleAutoProtection.shouldActivateAutoProtection(
            enabled: false,
            delay: .tenMinutes,
            idleSeconds: AutoRoutePromptsIdleDelay.tenMinutes.duration
        ))
    }

    func testIdleServiceActivatesAndRestoresEffectiveConfigWithoutChangingManualSetting() async {
        await MainActor.run {
            var idleSeconds: TimeInterval = 0
            var writes: [Bool] = []
            let settings = makeSettings { writes.append($0) }
            let protection = UserIdleAutoProtection(
                settings: settings,
                idleSecondsProvider: { idleSeconds },
                pollingInterval: 60
            )

            idleSeconds = AutoRoutePromptsIdleDelay.thirtyMinutes.duration
            protection.refreshNow()

            XCTAssertTrue(settings.idleAutoRoutePromptsToTerminalActive)
            XCTAssertFalse(settings.routePromptsToTerminal)
            XCTAssertTrue(settings.effectiveRoutePromptsToTerminal)
            XCTAssertEqual(writes.last, true)

            idleSeconds = 0
            protection.refreshNow()

            XCTAssertFalse(settings.idleAutoRoutePromptsToTerminalActive)
            XCTAssertFalse(settings.routePromptsToTerminal)
            XCTAssertFalse(settings.effectiveRoutePromptsToTerminal)
            XCTAssertEqual(writes.last, false)
        }
    }

    func testDisablingIdleProtectionClearsAutoEffectiveConfig() async {
        await MainActor.run {
            var writes: [Bool] = []
            let settings = makeSettings { writes.append($0) }

            settings.setIdleAutoRoutePromptsToTerminalActive(true)
            XCTAssertTrue(settings.effectiveRoutePromptsToTerminal)

            settings.autoRoutePromptsToTerminalWhenIdleEnabled = false

            XCTAssertFalse(settings.idleAutoRoutePromptsToTerminalActive)
            XCTAssertFalse(settings.effectiveRoutePromptsToTerminal)
            XCTAssertEqual(writes.last, false)
        }
    }

    func testManualRoutePromptsStillWinsWhenIdleProtectionIsInactive() async {
        await MainActor.run {
            var writes: [Bool] = []
            let settings = makeSettings { writes.append($0) }

            settings.routePromptsToTerminal = true

            XCTAssertTrue(settings.effectiveRoutePromptsToTerminal)
            XCTAssertEqual(writes.last, true)

            settings.autoRoutePromptsToTerminalWhenIdleEnabled = false

            XCTAssertTrue(settings.effectiveRoutePromptsToTerminal)
            XCTAssertEqual(writes.last, true)
        }
    }

    func testRemoteLauncherExportsBridgeRuntimeConfigPath() {
        let script = RemoteConnectorManager.remoteBridgeLauncherScript()

        XCTAssertTrue(script.contains("PING_ISLAND_BRIDGE_CONFIG"))
        XCTAssertTrue(script.contains("../bridge-config.json"))
    }

    @MainActor
    private func makeSettings(
        writer: @escaping (Bool) -> Void = { _ in }
    ) -> AppSettingsStore {
        let suiteName = "PingIslandTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettingsStore(
            defaults: defaults,
            bridgeRuntimeConfigWriter: { snapshot in
                writer(snapshot.routePromptsToTerminal)
            }
        )
    }
}
