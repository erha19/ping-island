import XCTest
@testable import Ping_Island

@MainActor
private final class AccessibilityStatusProbe {
    var isTrusted = false
    var promptValues: [Bool] = []

    func currentStatus(prompt: Bool) -> Bool {
        promptValues.append(prompt)
        return isTrusted
    }
}

@MainActor
private final class SettingsCategoryRefreshProbe {
    var soundRefreshCount = 0

    func refreshSoundPacks() async {
        soundRefreshCount += 1
    }
}

final class SettingsPanelViewModelTests: XCTestCase {
    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "PingIslandTests.SettingsPanelViewModel.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testQoderCLINoticeGateIsConsumedOnlyOnce() {
        let defaults = makeDefaults()
        let firstGate = QoderCLIHookRefreshNoticeGate(defaults: defaults)

        XCTAssertTrue(firstGate.consumeShouldShowNotice())
        XCTAssertFalse(firstGate.consumeShouldShowNotice())

        let secondGate = QoderCLIHookRefreshNoticeGate(defaults: defaults)

        XCTAssertFalse(secondGate.consumeShouldShowNotice())
    }

    func testRefreshAccessibilityStatusUsesLatestProviderValue() async {
        await MainActor.run {
            let defaults = makeDefaults()
            let probe = AccessibilityStatusProbe()
            let viewModel = SettingsPanelViewModel(
                qoderCLIHookRefreshStatusProvider: { nil },
                qoderCLIHookRefreshNoticeDefaults: defaults,
                accessibilityStatusProvider: { probe.currentStatus(prompt: $0) },
                accessibilitySettingsOpener: {}
            )

            viewModel.refreshAccessibilityStatus()
            XCTAssertFalse(viewModel.accessibilityEnabled)

            probe.isTrusted = true
            viewModel.refreshAccessibilityStatus()

            XCTAssertTrue(viewModel.accessibilityEnabled)
            XCTAssertEqual(probe.promptValues, [false, false])
        }
    }

    func testOpenAccessibilitySettingsPromptsBeforeOpeningSystemSettings() async {
        await MainActor.run {
            let defaults = makeDefaults()
            let probe = AccessibilityStatusProbe()
            var openSettingsCount = 0
            let viewModel = SettingsPanelViewModel(
                qoderCLIHookRefreshStatusProvider: { nil },
                qoderCLIHookRefreshNoticeDefaults: defaults,
                accessibilityStatusProvider: { probe.currentStatus(prompt: $0) },
                accessibilitySettingsOpener: { openSettingsCount += 1 }
            )

            viewModel.openAccessibilitySettings()

            XCTAssertFalse(viewModel.accessibilityEnabled)
            XCTAssertEqual(probe.promptValues, [true])
            XCTAssertEqual(openSettingsCount, 1)
        }
    }

    func testOpenAccessibilitySettingsDoesNotOpenSystemSettingsWhenPromptRefreshFindsAccess() async {
        await MainActor.run {
            let defaults = makeDefaults()
            let probe = AccessibilityStatusProbe()
            probe.isTrusted = true
            var openSettingsCount = 0
            let viewModel = SettingsPanelViewModel(
                qoderCLIHookRefreshStatusProvider: { nil },
                qoderCLIHookRefreshNoticeDefaults: defaults,
                accessibilityStatusProvider: { probe.currentStatus(prompt: $0) },
                accessibilitySettingsOpener: { openSettingsCount += 1 }
            )

            viewModel.openAccessibilitySettings()

            XCTAssertTrue(viewModel.accessibilityEnabled)
            XCTAssertEqual(probe.promptValues, [true])
            XCTAssertEqual(openSettingsCount, 0)
        }
    }

    func testCategoryRefreshSkipsRepeatedWorkUntilCacheExpires() async {
        let defaults = makeDefaults()

        await Task { @MainActor in
            let probe = SettingsCategoryRefreshProbe()
            var now = Date(timeIntervalSince1970: 1_000)
            let viewModel = SettingsPanelViewModel(
                qoderCLIHookRefreshStatusProvider: { nil },
                qoderCLIHookRefreshNoticeDefaults: defaults,
                accessibilityStatusProvider: { _ in false },
                accessibilitySettingsOpener: {},
                categoryRefreshInterval: 5,
                categoryRefreshClock: { now },
                soundPackRefreshProvider: {
                    await probe.refreshSoundPacks()
                }
            )

            await viewModel.refresh(for: .sound)
            await viewModel.refresh(for: .sound)
            XCTAssertEqual(probe.soundRefreshCount, 1)

            now = now.addingTimeInterval(6)
            await viewModel.refresh(for: .sound)
            XCTAssertEqual(probe.soundRefreshCount, 2)

            await viewModel.refresh(for: .sound, force: true)
            XCTAssertEqual(probe.soundRefreshCount, 3)
        }.value
    }
}
