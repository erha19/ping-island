import XCTest
@testable import Ping_Island

final class UsageSummaryPresenterTests: XCTestCase {
    func testProvidersIncludeClaudeAndCodexSnapshots() {
        let providers = UsageSummaryPresenter.providers(
            claudeSnapshot: ClaudeUsageSnapshot(
                fiveHour: ClaudeUsageWindow(usedPercentage: 42, resetsAt: Date(timeIntervalSince1970: 1_760_000_000)),
                sevenDay: nil,
                cachedAt: nil
            ),
            codexSnapshot: CodexUsageSnapshot(
                sourceFilePath: "/tmp/rollout.jsonl",
                capturedAt: nil,
                planType: "pro",
                limitID: "codex",
                tokenUsage: nil,
                windows: [
                    CodexUsageWindow(
                        key: "primary",
                        label: "5h",
                        usedPercentage: 13,
                        leftPercentage: 87,
                        windowMinutes: 300,
                        resetsAt: Date(timeIntervalSince1970: 1_775_158_295)
                    )
                ]
            ),
            mode: .used,
            now: Date(timeIntervalSince1970: 1_759_999_000),
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(providers.map(\.title), ["Claude", "Codex"])
        XCTAssertEqual(providers.first?.windows.first?.valueText, "42%")
        XCTAssertEqual(providers.last?.windows.first?.valueText, "13%")
    }

    func testRemainingModeFormatsRemainingPercentInEnglish() {
        let valueText = UsageSummaryPresenter.valueText(
            for: 13,
            mode: .remaining,
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(valueText, "87% left")
    }

    func testPreferredBatteryWindowUsesSevenDayWhenAvailable() {
        let provider = UsageSummaryProvider(
            id: "codex",
            title: "Codex",
            windows: [
                UsageSummaryWindow(
                    id: "codex-primary",
                    label: "5h",
                    valueText: "24% left",
                    resetText: nil,
                    severity: .warning,
                    remainingPercentage: 24
                ),
                UsageSummaryWindow(
                    id: "codex-secondary",
                    label: "7d",
                    valueText: "82% left",
                    resetText: nil,
                    severity: .healthy,
                    remainingPercentage: 82
                )
            ]
        )

        XCTAssertEqual(UsageSummaryPresenter.preferredBatteryWindow(for: provider)?.id, "codex-secondary")
    }

    func testSevenDayWindowSelectsOnlyRequestedProvider() {
        let providers = [
            UsageSummaryProvider(
                id: "claude",
                title: "Claude",
                windows: [
                    UsageSummaryWindow(
                        id: "claude-7d",
                        label: "7d",
                        valueText: "64% left",
                        resetText: nil,
                        severity: .healthy,
                        remainingPercentage: 64
                    )
                ]
            ),
            UsageSummaryProvider(
                id: "codex",
                title: "Codex",
                windows: [
                    UsageSummaryWindow(
                        id: "codex-5h",
                        label: "5h",
                        valueText: "22% left",
                        resetText: nil,
                        severity: .warning,
                        remainingPercentage: 22
                    ),
                    UsageSummaryWindow(
                        id: "codex-7d",
                        label: "7d",
                        valueText: "91% left",
                        resetText: nil,
                        severity: .healthy,
                        remainingPercentage: 91
                    )
                ]
            )
        ]

        XCTAssertEqual(
            UsageSummaryPresenter.sevenDayWindow(forProviderID: "codex", in: providers)?.id,
            "codex-7d"
        )
        XCTAssertNil(UsageSummaryPresenter.sevenDayWindow(forProviderID: "gemini", in: providers))
    }

    func testRemainingHelpTextIncludesAllWindows() {
        let provider = UsageSummaryProvider(
            id: "claude",
            title: "Claude",
            windows: [
                UsageSummaryWindow(
                    id: "claude-5h",
                    label: "5h",
                    valueText: "25% left",
                    resetText: "Resets in 2h",
                    severity: .warning,
                    remainingPercentage: 25
                ),
                UsageSummaryWindow(
                    id: "claude-7d",
                    label: "7d",
                    valueText: "91% left",
                    resetText: "Resets in 5d",
                    severity: .healthy,
                    remainingPercentage: 91
                )
            ]
        )

        XCTAssertEqual(
            UsageSummaryPresenter.remainingHelpText(for: provider, locale: Locale(identifier: "en")),
            """
            Claude
            5h · 25% left
            7d · 91% left
            """
        )
    }

    func testShouldShowSummaryHidesAttentionAndCompletionRoutes() {
        let providers = [
            UsageSummaryProvider(
                id: "claude",
                title: "Claude",
                windows: [
                    UsageSummaryWindow(
                        id: "claude-5h",
                        label: "5h",
                        valueText: "42%",
                        resetText: nil,
                        severity: .healthy,
                        remainingPercentage: 58
                    )
                ]
            )
        ]
        let session = SessionState(sessionId: "session", cwd: "/tmp/demo", phase: .processing)
        let notification = SessionCompletionNotification(session: session, kind: .completed)

        XCTAssertTrue(
            UsageSummaryPresenter.shouldShowSummary(
                for: .sessionList,
                showUsage: true,
                providers: providers
            )
        )
        XCTAssertFalse(
            UsageSummaryPresenter.shouldShowSummary(
                for: .attentionNotification(session),
                showUsage: true,
                providers: providers
            )
        )
        XCTAssertFalse(
            UsageSummaryPresenter.shouldShowSummary(
                for: .completionNotification(notification),
                showUsage: true,
                providers: providers
            )
        )
    }

    func testSeverityUsesRemainingQuotaThresholds() {
        XCTAssertEqual(UsageSummaryPresenter.severity(forUsedPercentage: 60), .healthy)
        XCTAssertEqual(UsageSummaryPresenter.severity(forUsedPercentage: 69), .healthy)
        XCTAssertEqual(UsageSummaryPresenter.severity(forUsedPercentage: 70), .warning)
        XCTAssertEqual(UsageSummaryPresenter.severity(forUsedPercentage: 75), .warning)
        XCTAssertEqual(UsageSummaryPresenter.severity(forUsedPercentage: 90), .warning)
        XCTAssertEqual(UsageSummaryPresenter.severity(forUsedPercentage: 91), .critical)
        XCTAssertEqual(UsageSummaryPresenter.severity(forUsedPercentage: 95), .critical)
    }

    func testFloatingBoltShowsOnlyBelowSixtyPercentRemaining() {
        let sixtyRemaining = UsageSummaryWindow(
            id: "sixty",
            label: "5h",
            valueText: "60% left",
            resetText: nil,
            severity: .healthy,
            remainingPercentage: 60
        )
        let belowSixtyRemaining = UsageSummaryWindow(
            id: "below-sixty",
            label: "5h",
            valueText: "59% left",
            resetText: nil,
            severity: .healthy,
            remainingPercentage: 59
        )

        XCTAssertFalse(UsageSummaryPresenter.shouldShowFloatingBolt(for: sixtyRemaining))
        XCTAssertTrue(UsageSummaryPresenter.shouldShowFloatingBolt(for: belowSixtyRemaining))
    }
}
