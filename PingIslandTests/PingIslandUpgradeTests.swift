import XCTest
@testable import Ping_Island

@MainActor
final class PingIslandUpgradeTests: XCTestCase {
    func testQuietHoursWindowHandlesMidnightWrap() {
        let window = AttentionQuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 8 * 60)

        XCTAssertTrue(window.contains(minuteOfDay: 23 * 60 + 30))
        XCTAssertTrue(window.contains(minuteOfDay: 2 * 60))
        XCTAssertFalse(window.contains(minuteOfDay: 12 * 60))
    }

    func testAttentionPolicySuppressesFocusedAndQuietSessions() {
        let settings = AttentionPolicySnapshot(
            smartSuppressionEnabled: false,
            quietHours: AttentionQuietHoursWindow(enabled: true, startMinutes: 60, endMinutes: 120),
            followFocusEnabled: true,
            temporaryMuteUntil: nil
        )
        let calendar = Calendar(identifier: .gregorian)
        let quietDate = DateComponents(calendar: calendar, year: 2026, month: 4, day: 27, hour: 1, minute: 30).date!
        let activeDate = DateComponents(calendar: calendar, year: 2026, month: 4, day: 27, hour: 13, minute: 0).date!

        XCTAssertTrue(AttentionPolicy.suppressesAutomaticPresentation(
            settings: settings,
            now: quietDate,
            calendar: calendar,
            terminalVisibleOnCurrentSpace: false,
            sessionFocused: false
        ))
        XCTAssertTrue(AttentionPolicy.suppressesAutomaticPresentation(
            settings: settings,
            now: activeDate,
            calendar: calendar,
            terminalVisibleOnCurrentSpace: false,
            sessionFocused: true
        ))
    }

    func testFileDropPromptUsesLocalPaths() {
        let prompt = SessionFileDropRouter.prompt(for: [
            URL(fileURLWithPath: "/tmp/image.png"),
            URL(fileURLWithPath: "/tmp/notes.md")
        ])

        XCTAssertTrue(prompt.contains("/tmp/image.png"))
        XCTAssertTrue(prompt.contains("/tmp/notes.md"))
        XCTAssertTrue(prompt.contains("Files dropped on Ping Island"))
    }

    func testWarpSQLPathEscaping() {
        XCTAssertEqual(WarpTabResolver.sqlEscaped("/tmp/bob's work"), "/tmp/bob''s work")
    }

    func testHookHealthReportsMissingForEmptyProfilePath() {
        let profile = ManagedHookClientProfile(
            id: "test-hooks-\(UUID().uuidString)",
            title: "Test Hooks",
            subtitle: "Test",
            iconSymbolName: "testtube.2",
            configurationRelativePath: ".ping-island-test-\(UUID().uuidString)/settings.json",
            bridgeSource: "claude",
            bridgeExtraArguments: [],
            defaultEnabled: false,
            brand: .neutral,
            events: [HookInstallEventDescriptor(name: "Stop", templates: [.plain])]
        )

        let snapshot = HookHealthCenter.snapshot(for: profile, now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(snapshot.status, .missing)
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertFalse(snapshot.installed)
    }

    func testHookHealthDoesNotTreatCurrentBridgeSignatureAsStale() {
        let currentHook = "/usr/local/bin/ping-island-bridge --source claude"
        let legacyHook = "/usr/local/bin/island-bridge --source claude"
        let legacyTypeName = "IslandBridge.install()"

        XCTAssertTrue(HookHealthCenter.containsCurrentIslandSignature(currentHook))
        XCTAssertFalse(HookHealthCenter.containsLegacyIslandBridgeSignature(currentHook))
        XCTAssertTrue(HookHealthCenter.containsLegacyIslandBridgeSignature(legacyHook))
        XCTAssertTrue(HookHealthCenter.containsLegacyIslandBridgeSignature(legacyTypeName))
    }

    func testSupplementalHookClientsResolveToMascotClients() {
        let expected: [(String, MascotClient, MascotKind)] = [
            ("kimi", .kimi, .gemini),
            ("factory", .factory, .opencode),
            ("trae", .trae, .cursor),
            ("stepfun", .stepfun, .qwen),
            ("antigravity", .antigravity, .cursor),
        ]

        for (profileID, client, mascot) in expected {
            let clientInfo = SessionClientInfo(kind: .custom, profileID: profileID)
            XCTAssertEqual(MascotClient(clientInfo: clientInfo, provider: .claude), client)
            XCTAssertEqual(MascotKind(clientInfo: clientInfo, provider: .claude), mascot)
            XCTAssertTrue(MascotClient.allCases.contains(client))
        }
    }

    func testApprovalDigestFlagsDestructiveCommands() {
        let permission = PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: ["command": AnyCodable("rm -rf build")],
            receivedAt: Date()
        )

        let digest = ApprovalReviewDigest(
            toolName: "Bash",
            formattedInput: permission.formattedInput,
            permission: permission,
            intervention: nil
        )

        XCTAssertEqual(digest.risk, .high)
        XCTAssertEqual(digest.command, "rm -rf build")
    }

    func testRelayMessageEncodingRoundTrips() throws {
        let message = IslandRelayMessage(
            id: "relay-1",
            kind: .permission,
            sessionID: "session-1",
            title: "Approve Bash",
            body: "Bash",
            clientName: "Codex",
            payload: ["tool": "Bash"],
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(IslandRelayMessage.self, from: data), message)
    }

    func testHardwareSimulatorProtocolRoundTrips() throws {
        let frame = HardwareSimulatorFrame(
            mascot: "codex",
            status: "approval",
            tool: "Bash",
            brightness: 1.4,
            orientation: .landscape,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let decoded = try HardwareSimulatorCodec.decode(try HardwareSimulatorCodec.encode(frame))

        XCTAssertEqual(decoded.brightness, 1)
        XCTAssertEqual(decoded.orientation, .landscape)
        XCTAssertTrue(HardwareSimulatorCodec.lineProtocol(frame).hasPrefix("PING_ISLAND_HW "))
    }
}
