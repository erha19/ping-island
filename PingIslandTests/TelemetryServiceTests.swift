import XCTest
@testable import Ping_Island

actor RecordingTelemetrySink: TelemetrySink {
    private var batches: [[TelemetryRecord]] = []

    func send(_ records: [TelemetryRecord], configuration _: TelemetryConfiguration) async throws {
        batches.append(records)
    }

    func sentRecords() -> [TelemetryRecord] {
        batches.flatMap { $0 }
    }
}

private final class TelemetryDateBox: @unchecked Sendable {
    nonisolated(unsafe) var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

final class TelemetryServiceTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "PingIslandTests.TelemetryService.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func makeService(
        defaults: UserDefaults,
        sink: RecordingTelemetrySink,
        dateBox: TelemetryDateBox,
        dailyEventLimit: Int = 200
    ) -> TelemetryService {
        TelemetryService(
            configuration: TelemetryConfiguration(
                slsHost: "cn-hangzhou.log.aliyuncs.com",
                dailyEventLimit: dailyEventLimit
            ),
            defaults: defaults,
            sink: sink,
            calendar: calendar,
            maxBatchSize: 1,
            now: { dateBox.date }
        )
    }

    func testConfigurationBuildsSLSWebTrackingEndpoint() {
        let configuration = TelemetryConfiguration(
            slsHost: "https://cn-hangzhou.log.aliyuncs.com/",
            project: "ping-island",
            logstore: "ping-island"
        )

        XCTAssertEqual(
            configuration.endpointURL?.absoluteString,
            "https://ping-island.cn-hangzhou.log.aliyuncs.com/logstores/ping-island/track"
        )
    }

    func testTelemetryDoesNotSendWhenConsentIsDisabled() async {
        let defaults = makeDefaults()
        let sink = RecordingTelemetrySink()
        let dateBox = TelemetryDateBox(date(year: 2026, month: 5, day: 16))
        let service = makeService(defaults: defaults, sink: sink, dateBox: dateBox)

        await service.recordAppLaunch()
        dateBox.date = date(year: 2026, month: 5, day: 17)
        await service.recordAppLaunch()

        let records = await sink.sentRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testTelemetryUploadsOneDailyUsageSnapshotForCompletedDay() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: TelemetryConsent.analyticsEnabledKey)
        defaults.set(IslandSurfaceMode.floatingPet.rawValue, forKey: AppSettingsDefaultKeys.surfaceMode)
        let sink = RecordingTelemetrySink()
        let dateBox = TelemetryDateBox(date(year: 2026, month: 5, day: 16))
        let service = makeService(defaults: defaults, sink: sink, dateBox: dateBox)

        await service.recordAppLaunch()
        await service.recordIntegrationSnapshot()

        let sameDayRecords = await sink.sentRecords()
        XCTAssertTrue(sameDayRecords.isEmpty)

        dateBox.date = date(year: 2026, month: 5, day: 17)
        await service.recordAppLaunch()
        await service.recordIntegrationSnapshot()

        let records = await sink.sentRecords()
        XCTAssertEqual(records.count, 1)
        let fields = try XCTUnwrap(records.first?.fields)
        XCTAssertEqual(fields["event"], "daily_usage_snapshot")
        XCTAssertEqual(fields["report_date"], "2026-5-16")
        XCTAssertEqual(fields["active_device"], "true")
        XCTAssertEqual(fields["app_launch_count"], "1")
        XCTAssertEqual(fields["surface_mode"], IslandSurfaceMode.floatingPet.rawValue)
        XCTAssertNotNil(fields["anonymous_user_id"])

        await service.recordIntegrationSnapshot()
        let recordsAfterRepeatedSnapshotCheck = await sink.sentRecords()
        XCTAssertEqual(recordsAfterRepeatedSnapshotCheck.count, 1)
    }

    func testDailyUsageSnapshotAggregatesSessionsSettingsAndTmux() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: TelemetryConsent.analyticsEnabledKey)
        defaults.set(IslandSurfaceMode.notch.rawValue, forKey: AppSettingsDefaultKeys.surfaceMode)
        let sink = RecordingTelemetrySink()
        let dateBox = TelemetryDateBox(date(year: 2026, month: 5, day: 16))
        let service = makeService(defaults: defaults, sink: sink, dateBox: dateBox)

        let session = SessionState(
            sessionId: "session-1",
            cwd: "/tmp/project",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex"),
            ingress: .hookBridge,
            isInTmux: true
        )

        await service.recordAppLaunch()
        await service.record(
            .settingChanged,
            properties: [
                "setting_key": "showUsage",
                "value": "true",
                "cwd": "/Users/example/private-project"
            ]
        )
        await service.record(.settingChanged, properties: ["setting_key": "showUsage", "value": "false"])
        await service.recordSessionDetected(session)
        await service.recordSessionDetected(session)
        await service.recordSessionCompleted(session)

        dateBox.date = date(year: 2026, month: 5, day: 17)
        await service.recordAppLaunch()

        let records = await sink.sentRecords()
        let fields = try XCTUnwrap(records.first?.fields)
        XCTAssertEqual(fields["event"], "daily_usage_snapshot")
        XCTAssertEqual(fields["session_count"], "1")
        XCTAssertEqual(fields["client_session_counts"], "codex=1")
        XCTAssertEqual(fields["provider_session_counts"], "codex=1")
        XCTAssertEqual(fields["tmux_session_count"], "1")
        XCTAssertEqual(fields["setting_change_counts"], "showUsage=2")
        XCTAssertNil(fields["cwd"])
    }

    func testDailyLimitZeroDisablesSnapshotUpload() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: TelemetryConsent.analyticsEnabledKey)
        let sink = RecordingTelemetrySink()
        let dateBox = TelemetryDateBox(date(year: 2026, month: 5, day: 16))
        let service = makeService(defaults: defaults, sink: sink, dateBox: dateBox, dailyEventLimit: 0)

        await service.recordAppLaunch()
        dateBox.date = date(year: 2026, month: 5, day: 17)
        await service.recordAppLaunch()

        let records = await sink.sentRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testDisablingTelemetryDropsPendingDailyAggregate() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: TelemetryConsent.analyticsEnabledKey)
        let sink = RecordingTelemetrySink()
        let dateBox = TelemetryDateBox(date(year: 2026, month: 5, day: 16))
        let service = makeService(defaults: defaults, sink: sink, dateBox: dateBox)

        await service.recordAppLaunch()
        await service.record(.settingChanged, properties: ["setting_key": "showUsage", "value": "true"])
        await service.handleConsentChanged(enabled: false)

        defaults.set(true, forKey: TelemetryConsent.analyticsEnabledKey)
        await service.handleConsentChanged(enabled: true)
        dateBox.date = date(year: 2026, month: 5, day: 17)
        await service.recordAppLaunch()

        let records = await sink.sentRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.fields["app_launch_count"], "1")
        XCTAssertEqual(records.first?.fields["setting_change_counts"], "none")
    }
}
