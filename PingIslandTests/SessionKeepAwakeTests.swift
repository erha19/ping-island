import XCTest
@testable import Ping_Island

nonisolated private final class KeepAwakeTestAssertionClient: SessionKeepAwakeAssertionClient {
    var isHolding = false
    var allowsAcquire = true
    var acquisitions = 0
    var releases = 0

    func acquire(reason: String) -> Bool {
        guard allowsAcquire else { return false }
        if !isHolding { acquisitions += 1 }
        isHolding = true
        return true
    }

    func release() {
        if isHolding { releases += 1 }
        isHolding = false
    }
}

nonisolated private final class KeepAwakeTestEnvironment {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var batteryReads = 0
    var battery = SessionKeepAwakeBatteryStatus(isOnBattery: false, percentage: 80)
}


@MainActor
final class SessionKeepAwakeTests: XCTestCase {
    private static var retainedStores: [AppSettingsStore] = []

    private func makeSettings(_ mode: KeepAwakeMode = .auto) -> AppSettingsStore {
        let defaults = UserDefaults(suiteName: "PingIslandTests.KeepAwake.\(UUID().uuidString)")!
        let settings = AppSettingsStore(defaults: defaults, bridgeRuntimeConfigWriter: { _ in })
        settings.keepAwakeMode = mode
        Self.retainedStores.append(settings)
        return settings
    }

    private func makeController(
        mode: KeepAwakeMode = .auto,
        environment: KeepAwakeTestEnvironment,
        assertion: KeepAwakeTestAssertionClient,
        powerPollInterval: TimeInterval = 30
    ) -> SessionKeepAwakeController {
        SessionKeepAwakeController(
            settings: makeSettings(mode),
            assertionClient: assertion,
            batteryStatusProvider: {
                environment.batteryReads += 1
                return environment.battery
            },
            nowProvider: { environment.now },
            observeSessions: false,
            powerPollInterval: powerPollInterval
        )
    }

    func testPowerChangeReleasesAndRestoresWithoutSessionEvents() {
        let environment = KeepAwakeTestEnvironment()
        let assertion = KeepAwakeTestAssertionClient()
        let controller = makeController(environment: environment, assertion: assertion)
        controller.start()
        defer { controller.stop() }
        controller.handleWorkingSessionChange(true)
        XCTAssertTrue(controller.isHoldingAssertion)

        environment.battery = .init(isOnBattery: true, percentage: 35)
        controller.refreshPowerState()
        XCTAssertFalse(controller.isHoldingAssertion)
        XCTAssertEqual(controller.decision, .release(.batteryFloor(percent: 35)))

        environment.battery.isOnBattery = false
        controller.refreshPowerState()
        XCTAssertTrue(controller.isHoldingAssertion)
        XCTAssertEqual(controller.decision, .hold(.sessionWorking))
        XCTAssertEqual(assertion.acquisitions, 2)
        XCTAssertEqual(assertion.releases, 1)
    }

    func testLongRunningTaskGetsFullGraceFromExitAndIdleEventsDoNotExtendIt() {
        let environment = KeepAwakeTestEnvironment()
        let assertion = KeepAwakeTestAssertionClient()
        let controller = makeController(environment: environment, assertion: assertion)
        controller.start()
        defer { controller.stop() }
        controller.handleWorkingSessionChange(true)
        environment.now.addTimeInterval(600)
        controller.handleWorkingSessionChange(false)
        XCTAssertEqual(controller.decision, .hold(.graceWindow))
        XCTAssertTrue(controller.isHoldingAssertion)

        environment.now.addTimeInterval(119)
        controller.handleWorkingSessionChange(false)
        controller.refreshPowerState()
        XCTAssertTrue(controller.isHoldingAssertion)
        environment.now.addTimeInterval(1)
        controller.refreshPowerState()
        XCTAssertFalse(controller.isHoldingAssertion)
        XCTAssertEqual(controller.decision, .release(.nothingWorking))
        XCTAssertEqual(assertion.acquisitions, 1)
        XCTAssertEqual(assertion.releases, 1)
    }

    func testResumedWorkStartsANewGraceWindow() {
        let environment = KeepAwakeTestEnvironment()
        let assertion = KeepAwakeTestAssertionClient()
        let controller = makeController(environment: environment, assertion: assertion)
        controller.start()
        defer { controller.stop() }
        controller.handleWorkingSessionChange(true)
        controller.handleWorkingSessionChange(false)
        environment.now.addTimeInterval(100)
        controller.handleWorkingSessionChange(true)
        environment.now.addTimeInterval(100)
        controller.handleWorkingSessionChange(false)
        environment.now.addTimeInterval(119)
        controller.refreshPowerState()
        XCTAssertTrue(controller.isHoldingAssertion)
        environment.now.addTimeInterval(1)
        controller.refreshPowerState()
        XCTAssertFalse(controller.isHoldingAssertion)
    }

    func testStopPreventsPowerOrSessionEventsFromReacquiringUntilRestart() {
        let environment = KeepAwakeTestEnvironment()
        let assertion = KeepAwakeTestAssertionClient()
        let controller = makeController(environment: environment, assertion: assertion)
        controller.start()
        controller.handleWorkingSessionChange(true)
        controller.stop()
        controller.refreshPowerState()
        controller.handleWorkingSessionChange(true)
        XCTAssertFalse(controller.isHoldingAssertion)
        XCTAssertEqual(assertion.acquisitions, 1)
        controller.start()
        XCTAssertTrue(controller.isHoldingAssertion)
        controller.stop()
    }

    func testAlwaysModeHoldsWithoutSessionsAndIgnoresBatteryFloor() {
        let environment = KeepAwakeTestEnvironment()
        environment.battery = .init(isOnBattery: true, percentage: 5)
        let assertion = KeepAwakeTestAssertionClient()
        let controller = makeController(mode: .always, environment: environment, assertion: assertion)
        controller.start()
        defer { controller.stop() }
        environment.now.addTimeInterval(600)
        controller.refreshPowerState()
        XCTAssertTrue(controller.isHoldingAssertion)
        XCTAssertEqual(controller.decision, .hold(.alwaysOn))
        XCTAssertEqual(assertion.acquisitions, 1)
    }

    func testOffModeDoesNotAcquireForWorkingSessions() {
        let environment = KeepAwakeTestEnvironment()
        let assertion = KeepAwakeTestAssertionClient()
        let controller = makeController(mode: .off, environment: environment, assertion: assertion)
        controller.start()
        defer { controller.stop() }
        controller.handleWorkingSessionChange(true)
        controller.refreshPowerState()
        XCTAssertFalse(controller.isHoldingAssertion)
        XCTAssertEqual(controller.decision, .release(.disabled))
        XCTAssertEqual(assertion.acquisitions, 0)
    }

    func testFailedAcquisitionReportsActualStateAndCanRetry() {
        let environment = KeepAwakeTestEnvironment()
        let assertion = KeepAwakeTestAssertionClient()
        assertion.allowsAcquire = false
        let controller = makeController(environment: environment, assertion: assertion)
        controller.start()
        defer { controller.stop() }
        controller.handleWorkingSessionChange(true)
        XCTAssertEqual(controller.decision, .hold(.sessionWorking))
        XCTAssertFalse(controller.isHoldingAssertion)
        assertion.allowsAcquire = true
        controller.refreshPowerState()
        XCTAssertTrue(controller.isHoldingAssertion)
    }

    func testScheduledPowerPollingRestoresAfterLowBatteryWithoutSessionEvents() async throws {
        let environment = KeepAwakeTestEnvironment()
        environment.battery = .init(isOnBattery: true, percentage: 20)
        let assertion = KeepAwakeTestAssertionClient()
        let controller = makeController(environment: environment, assertion: assertion, powerPollInterval: 0.02)
        controller.start()
        defer { controller.stop() }
        controller.handleWorkingSessionChange(true)
        XCTAssertFalse(controller.isHoldingAssertion)
        environment.battery.isOnBattery = false

        let deadline = Date().addingTimeInterval(1)
        while !controller.isHoldingAssertion && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(controller.isHoldingAssertion, "Scheduled power checks must survive a low-battery release")
        XCTAssertEqual(controller.decision, .hold(.sessionWorking))
    }

    func testAlwaysAndIdleAutoDoNotKeepPollingBattery() async throws {
        for mode in [KeepAwakeMode.always, .auto] {
            let environment = KeepAwakeTestEnvironment()
            let assertion = KeepAwakeTestAssertionClient()
            let controller = makeController(mode: mode, environment: environment, assertion: assertion, powerPollInterval: 0.02)
            controller.start()
            // Drain the initial settings publisher delivery before measuring timers.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            let initialReads = environment.batteryReads
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(environment.batteryReads, initialReads, "No battery timer needed for \(mode) without working or grace")
            controller.stop()
        }
    }

    func testSystemAssertionAcquireAndReleaseAreIdempotent() {
        let assertion = IOPMSystemSleepAssertionClient()
        defer { assertion.release() }
        XCTAssertTrue(assertion.acquire(reason: "Ping Island unit test"))
        XCTAssertTrue(assertion.acquire(reason: "Ping Island unit test"))
        XCTAssertTrue(assertion.isHolding)
        assertion.release()
        XCTAssertFalse(assertion.isHolding)
        assertion.release()
        XCTAssertFalse(assertion.isHolding)
    }

    func testSystemAssertionCanBeReleasedBeforeAcquireAndReacquired() {
        let assertion = IOPMSystemSleepAssertionClient()
        defer { assertion.release() }
        assertion.release()
        XCTAssertFalse(assertion.isHolding)
        XCTAssertTrue(assertion.acquire(reason: "Ping Island unit test"))
        assertion.release()
        XCTAssertTrue(assertion.acquire(reason: "Ping Island unit test"))
        XCTAssertTrue(assertion.isHolding)
    }

}
