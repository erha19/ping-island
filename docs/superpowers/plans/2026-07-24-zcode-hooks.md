# ZCode Hooks Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Z.ai ZCode as a first-class managed hook client that installs/uninstalls Claude-compatible hooks under `~/.zcode/cli/config.json` → `hooks.events` with `hooks.enabled = true`.

**Architecture:** Register a `zcode-hooks` profile in `ClientProfileRegistry`, then special-case the nested ZCode JSON shape inside `HookInstaller` (same pattern as Copilot / Claude `statusLine`). Prefer small shared helpers so `updateHooks`, `removeManagedHooks`, `containsManagedHooks`, and `updatedConfigurationData` stay consistent. Cover behavior with `PingIslandTests` against `updatedConfigurationData` plus a profile-shape test.

**Tech Stack:** Swift / AppKit settings UI (existing), `HookInstaller` JSON merge, XCTest (`PingIslandTests`).

**Spec:** `docs/superpowers/specs/2026-07-24-zcode-hooks-design.md`

## Global Constraints

- Config path: `.zcode/cli/config.json` under the hook home directory.
- Nested shape only: event map lives at `hooks.events`; install must set `hooks.enabled = true`.
- Preserve foreign hook entries and non-event keys (`maxOutputBytes`, `timeoutMs`, plugins, etc.).
- Uninstall must not force `hooks.enabled = false`.
- Matchers use `.*` (not Claude `*`).
- Events v1: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` (timeout 86400), `Stop`. No `SessionEnd` / `Notification` / `SubagentStop` / `PreCompact`.
- No mascot, no IDE extension, no remote bootstrap in this plan.
- Do not modify Prototype’s separate `HookInstaller` unless a test there is broken by shared types (none expected).
- Commits: only when the user explicitly asks; skip commit steps during execution unless requested.

---

## File Structure

| File | Role |
|---|---|
| `PingIsland/Models/ClientProfile.swift` | Add `zcode-hooks` `ManagedHookClientProfile`. |
| `PingIsland/Services/Hooks/HookInstaller.swift` | Nested read/write/detect helpers; wire into update/remove/contains/`updatedConfigurationData`; optional custom-path resolution for `.zcode`. |
| `PingIslandTests/ZCodeHookInstallerTests.swift` | Nested install / preserve / uninstall / detect tests via `updatedConfigurationData`. |
| `PingIslandTests/ClientProfileIconTests.swift` | Profile shape assertions for `zcode-hooks`. |
| `AGENTS.md` | Change Routing bullet for ZCode. |
| `PingIsland/UI/Views/SettingsWindowView.swift` | Only if custom-path hint for ZCode is added (optional UX; Task 3). |

No new installation kind. No new brand enum.

---

### Task 1: Profile registry + failing tests

**Files:**
- Modify: `PingIsland/Models/ClientProfile.swift` (insert into `managedHookProfiles`, near other always-visible CLI profiles — after `opencode-hooks` / before `kimi-hooks` is fine)
- Create: `PingIslandTests/ZCodeHookInstallerTests.swift`
- Modify: `PingIslandTests/ClientProfileIconTests.swift`
- Modify: `AGENTS.md` (docs travel with the profile)

**Interfaces:**
- Consumes: `ManagedHookClientProfile`, `ClientProfileRegistry.managedHookProfile(id:)`, `HookInstaller.updatedConfigurationData(...)`
- Produces: profile `id == "zcode-hooks"` with the field values below; tests initially fail on nested install until Task 2

**Profile values (exact):**

```swift
ManagedHookClientProfile(
    id: "zcode-hooks",
    title: "ZCode",
    subtitle: "管理 ~/.zcode/cli/config.json，按 ZCode hooks.events 协议接入 Island",
    alwaysVisibleInSettings: true,
    iconSymbolName: "z.square.fill",
    configurationRelativePath: ".zcode/cli/config.json",
    bridgeSource: "claude",
    bridgeExtraArguments: [
        "--client-kind", "zcode",
        "--client-name", "ZCode",
        "--client-originator", "ZCode"
    ],
    defaultEnabled: false,
    brand: .claude,
    events: [
        HookInstallEventDescriptor(name: "SessionStart", templates: [.matcher(".*")]),
        HookInstallEventDescriptor(name: "UserPromptSubmit", templates: [.matcher(".*")]),
        HookInstallEventDescriptor(name: "PreToolUse", templates: [.matcher(".*")]),
        HookInstallEventDescriptor(name: "PostToolUse", templates: [.matcher(".*")]),
        HookInstallEventDescriptor(name: "PostToolUseFailure", templates: [.matcher(".*")]),
        HookInstallEventDescriptor(name: "PermissionRequest", templates: [.matcher(".*")], timeout: 86_400),
        HookInstallEventDescriptor(name: "Stop", templates: [.matcher(".*")]),
    ]
)
```

- [ ] **Step 1: Write the profile-shape test**

Add to `PingIslandTests/ClientProfileIconTests.swift`:

```swift
func testZCodeHookProfileUsesNestedCLIConfigPath() throws {
    let profile = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))

    XCTAssertEqual(profile.title, "ZCode")
    XCTAssertEqual(profile.configurationRelativePaths, [".zcode/cli/config.json"])
    XCTAssertTrue(profile.alwaysVisibleInSettings)
    XCTAssertFalse(profile.defaultEnabled)
    XCTAssertEqual(profile.bridgeSource, "claude")
    XCTAssertEqual(
        profile.bridgeExtraArguments,
        [
            "--client-kind", "zcode",
            "--client-name", "ZCode",
            "--client-originator", "ZCode"
        ]
    )
    XCTAssertEqual(profile.brand, .claude)
    XCTAssertEqual(Set(profile.events.map(\.name)), [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionRequest", "Stop"
    ])
    XCTAssertFalse(profile.events.contains { $0.name == "SessionEnd" })
    XCTAssertEqual(profile.events.first { $0.name == "PermissionRequest" }?.timeout, 86_400)
}
```

- [ ] **Step 2: Write failing nested install/uninstall tests**

Create `PingIslandTests/ZCodeHookInstallerTests.swift`:

```swift
import XCTest
@testable import Ping_Island

final class ZCodeHookInstallerTests: XCTestCase {
    private var profile: ManagedHookClientProfile {
        get throws {
            try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
        }
    }

    private var islandCommand: String {
        get throws {
            let profile = try profile
            return HookInstaller.managedBridgeCommand(
                source: profile.bridgeSource,
                extraArguments: profile.bridgeExtraArguments,
                launcherPath: "/tmp/.ping-island/bin/ping-island-bridge",
                socketPath: "/tmp/.ping-island/run/agent-hook.sock"
            )
        }
    }

    func testUpdatedConfigurationDataInstallsUnderHooksEventsAndEnablesHooks() throws {
        let existingJSON = """
        {
          "plugins": { "dirs": ["/tmp/example"] },
          "hooks": {
            "enabled": false,
            "maxOutputBytes": 32768,
            "timeoutMs": 300000,
            "events": {
              "Stop": [
                {
                  "matcher": ".*",
                  "hooks": [
                    { "type": "command", "command": "/usr/bin/echo foreign" }
                  ]
                }
              ]
            }
          }
        }
        """.data(using: .utf8)

        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: try profile,
            customCommand: try islandCommand,
            installing: true
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, true)
        XCTAssertEqual(hooks["maxOutputBytes"] as? Int, 32768)
        XCTAssertEqual(hooks["timeoutMs"] as? Int, 300000)
        XCTAssertNotNil(object["plugins"])

        let events = try XCTUnwrap(hooks["events"] as? [String: Any])
        XCTAssertNil(hooks["PreToolUse"]) // must not flatten into hooks root

        let preToolUse = try XCTUnwrap(events["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.first?["matcher"] as? String, ".*")
        let preCommand = try XCTUnwrap((preToolUse.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(preCommand.contains("ping-island-bridge"))
        XCTAssertTrue(preCommand.contains("--client-kind zcode") || preCommand.contains("--client-kind 'zcode'"))

        let stop = try XCTUnwrap(events["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2) // foreign + Island
        let stopCommands = stop.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        XCTAssertTrue(stopCommands.contains("/usr/bin/echo foreign"))
    }

    func testUpdatedConfigurationDataUninstallRemovesOnlyIslandEntries() throws {
        let existingJSON = """
        {
          "hooks": {
            "enabled": true,
            "timeoutMs": 300000,
            "events": {
              "Stop": [
                {
                  "matcher": ".*",
                  "hooks": [
                    { "type": "command", "command": "/usr/bin/echo foreign" }
                  ]
                },
                {
                  "matcher": ".*",
                  "hooks": [
                    {
                      "type": "command",
                      "command": "'/tmp/.ping-island/bin/ping-island-bridge' --source claude --client-kind zcode --client-name ZCode --client-originator ZCode"
                    }
                  ]
                }
              ]
            }
          }
        }
        """.data(using: .utf8)

        let data = HookInstaller.updatedConfigurationData(
            existingData: existingJSON,
            profile: try profile,
            customCommand: try islandCommand,
            installing: false
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        XCTAssertEqual(hooks["enabled"] as? Bool, true)
        XCTAssertEqual(hooks["timeoutMs"] as? Int, 300000)

        let events = try XCTUnwrap(hooks["events"] as? [String: Any])
        let stop = try XCTUnwrap(events["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        let command = try XCTUnwrap((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertEqual(command, "/usr/bin/echo foreign")
    }
}
```

- [ ] **Step 3: Run tests to verify profile missing / nested write fails**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClientProfileIconTests/testZCodeHookProfileUsesNestedCLIConfigPath -only-testing:PingIslandTests/ZCodeHookInstallerTests
```

Expected: FAIL — `managedHookProfile(id: "zcode-hooks")` is nil and/or install still writes flat `hooks.PreToolUse`.

- [ ] **Step 4: Add the profile to `ClientProfileRegistry.managedHookProfiles`**

Insert the profile block from **Profile values (exact)** above into `PingIsland/Models/ClientProfile.swift`.

- [ ] **Step 5: Add AGENTS.md Change Routing bullet**

Under the Claude-compatible hook client list in `AGENTS.md`, add:

```markdown
  - ZCode hooks are managed through `~/.zcode/cli/config.json`. Event entries live under `hooks.events` (not a flat Claude-style `hooks` map); install must set `hooks.enabled` to `true`. Matchers use `.*`. ZCode does not use `SessionEnd` in the v1 managed event set.
```

- [ ] **Step 6: Re-run profile test**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClientProfileIconTests/testZCodeHookProfileUsesNestedCLIConfigPath
```

Expected: PASS. `ZCodeHookInstallerTests` still FAIL on nested assertions.

- [ ] **Step 7: Commit (only if user asked)**

```bash
git add PingIsland/Models/ClientProfile.swift PingIslandTests/ClientProfileIconTests.swift PingIslandTests/ZCodeHookInstallerTests.swift AGENTS.md
git commit -m "$(cat <<'EOF'
Add ZCode managed hook profile and failing nested-config tests.

EOF
)"
```

---

### Task 2: Nested hooks helpers in HookInstaller

**Files:**
- Modify: `PingIsland/Services/Hooks/HookInstaller.swift` — `updatedConfigurationData`, `updateHooks`, `removeManagedHooks`, `containsManagedHooks(at:profile:)`, and `isIslandManagedHookCommand` zcode case
- Test: `PingIslandTests/ZCodeHookInstallerTests.swift`

**Interfaces:**
- Consumes: profile `id == "zcode-hooks"`
- Produces: helpers that treat the event map as `hooks["events"]` for ZCode and as `hooks` itself for other JSON clients; `updatedConfigurationData` / disk update/remove/detect all agree

- [ ] **Step 1: Add private helpers near the JSON hook merge helpers**

Place near `removingIslandManagedHooks` / `updateHooks` in `HookInstaller.swift`:

```swift
private static func usesNestedEventsHooksObject(_ profile: ManagedHookClientProfile?) -> Bool {
    profile?.id == "zcode-hooks"
}

/// Event-name → entries map. For ZCode this is `hooks.events`; otherwise `hooks` itself.
private static func eventEntriesMap(
    fromHooksObject hooks: [String: Any],
    profile: ManagedHookClientProfile?
) -> [String: Any] {
    if usesNestedEventsHooksObject(profile) {
        return hooks["events"] as? [String: Any] ?? [:]
    }
    return hooks
}

/// Writes the event map back. For ZCode, preserves sibling keys and optionally sets `enabled`.
private static func hooksObject(
    embeddingEventEntries events: [String: Any],
    intoExistingHooks existing: [String: Any],
    profile: ManagedHookClientProfile?,
    setEnabledTrue: Bool
) -> [String: Any] {
    if usesNestedEventsHooksObject(profile) {
        var hooks = existing
        hooks["events"] = events
        if setEnabledTrue {
            hooks["enabled"] = true
        }
        return hooks
    }
    return events
}
```

- [ ] **Step 2: Wire `updatedConfigurationData` JSON branch**

In `updatedConfigurationData`’s `.jsonHooks` case, replace the flat `hooks` mutation with:

```swift
case .jsonHooks:
    var hooksObject = json["hooks"] as? [String: Any] ?? [:]
    var events = eventEntriesMap(fromHooksObject: hooksObject, profile: profile)

    if installing {
        events = removingIslandManagedHooks(from: events, profile: profile)
        let preferredFirst = profile.id == "qoder-cli-hooks"
            || profile.id == "qoder-cn-cli-hooks"
            || profile.id == "codebuddy-cli-hooks"
        for event in profile.events {
            let existingEvent = sanitizedHookEntries(
                events[event.name] as? [[String: Any]],
                removingCommandPrefixes: removingCommandPrefixes
            )
            events[event.name] = normalizedHookEntries(
                existingEvent,
                preferred: makeHookEntries(command: customCommand, event: event),
                preferredFirst: preferredFirst,
                profile: profile
            )
        }
        hooksObject = Self.hooksObject(
            embeddingEventEntries: events,
            intoExistingHooks: hooksObject,
            profile: profile,
            setEnabledTrue: true
        )
        json["hooks"] = hooksObject
    } else {
        for (event, value) in events {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                isIslandManagedHookEntry(entry, for: profile)
            }
            if entries.isEmpty {
                events.removeValue(forKey: event)
            } else {
                events[event] = entries
            }
        }
        hooksObject = Self.hooksObject(
            embeddingEventEntries: events,
            intoExistingHooks: hooksObject,
            profile: profile,
            setEnabledTrue: false
        )
        // For flat Claude-style configs, empty event map means remove `hooks`.
        // For ZCode, keep the hooks object (enabled / timeoutMs / empty events) so we do not wipe metadata.
        if usesNestedEventsHooksObject(profile) {
            json["hooks"] = hooksObject
        } else if events.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooksObject
        }
    }
```

Keep Copilot / other installation kinds unchanged.

- [ ] **Step 3: Mirror the same embedding in `updateHooks` and `removeManagedHooks`**

In `updateHooks` (non-copilot path), after building the event map via `removingIslandManagedHooks` + merge, write back with `hooksObject(..., setEnabledTrue: true)` instead of `json["hooks"] = hooks`.

In `removeManagedHooks`, load `hooksObject`, operate on `eventEntriesMap`, write back with `hooksObject(..., setEnabledTrue: false)`, and for non-ZCode keep the existing “remove entire hooks key if empty” behavior.

- [ ] **Step 4: Fix `containsManagedHooks(at:profile:)` for nested events**

```swift
private static func containsManagedHooks(at url: URL, profile: ManagedHookClientProfile? = nil) -> Bool {
    guard let data = try? Data(contentsOf: url),
          let json = HookConfigParser.parseJSONObject(from: data),
          let hooks = json["hooks"] as? [String: Any] else {
        return false
    }

    let events: [String: Any]
    if let profile, usesNestedEventsHooksObject(profile) {
        events = eventEntriesMap(fromHooksObject: hooks, profile: profile)
    } else if let nested = hooks["events"] as? [String: Any] {
        // ZCode-shaped file without a profile hint
        events = nested
    } else {
        events = hooks
    }

    for (_, value) in events {
        if let entries = value as? [[String: Any]] {
            for entry in entries {
                if isIslandManagedHookEntry(entry, for: profile) {
                    return true
                }
            }
        }
    }
    return false
}
```

- [ ] **Step 5: Add `zcode-hooks` to `isIslandManagedHookCommand` switch**

```swift
case "zcode-hooks":
    return hookCommand(command, hasClientKind: "zcode")
```

- [ ] **Step 6: Run ZCode tests**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ZCodeHookInstallerTests -only-testing:PingIslandTests/ClientProfileIconTests/testZCodeHookProfileUsesNestedCLIConfigPath
```

Expected: PASS.

- [ ] **Step 7: Commit (only if user asked)**

```bash
git add PingIsland/Services/Hooks/HookInstaller.swift PingIslandTests/ZCodeHookInstallerTests.swift
git commit -m "$(cat <<'EOF'
Teach HookInstaller nested hooks.events writes for ZCode.

EOF
)"
```

---

### Task 3: Custom install path UX for `.zcode`

**Files:**
- Modify: `PingIsland/Services/Hooks/HookInstaller.swift` — `customInstallationURL`
- Modify: `PingIsland/UI/Views/SettingsWindowView.swift` — `CustomHookInstallSheet.installHint` / path resolution description (mirror Hermes/OpenClaw hints)

**Interfaces:**
- Consumes: `profile.id == "zcode-hooks"`, user-selected base directory
- Produces: selecting `~/.zcode` resolves to `~/.zcode/cli/config.json`; selecting `~/.zcode/cli` resolves to `.../cli/config.json`

- [ ] **Step 1: Extend `customInstallationURL` for ZCode**

In the `.jsonHooks` branch (or a `profile.id` check before the generic append):

```swift
case .jsonHooks, .pluginFile:
    if profile.id == "zcode-hooks" {
        if baseDirectory.lastPathComponent == ".zcode" {
            return baseDirectory
                .appendingPathComponent("cli", isDirectory: true)
                .appendingPathComponent("config.json")
        }
        if baseDirectory.lastPathComponent == "cli" {
            return baseDirectory.appendingPathComponent("config.json")
        }
    }
    return baseDirectory.appendingPathComponent(profile.primaryConfigurationURL.lastPathComponent)
```

Update `CustomHookInstallSheet.resolvedInstallTargetDescription` / `installHint` so when `zcode-hooks` is selected the hint says ZCode may choose `~/.zcode` or `~/.zcode/cli`.

- [ ] **Step 2: Manual verification checklist**

1. Build/run Debug app (`./scripts/run-debug.sh` or Xcode).
2. Settings → Integration: **ZCode** row visible.
3. Install ZCode → `~/.zcode/cli/config.json` has `hooks.enabled: true` and Island commands under `hooks.events` (foreign entries preserved).
4. 添加自定义 Hook 配置 dropdown includes **ZCode**.
5. Uninstall ZCode → Island entries gone; `enabled` still true if foreign hooks remain.

- [ ] **Step 3: Commit (only if user asked)**

```bash
git add PingIsland/Services/Hooks/HookInstaller.swift PingIsland/UI/Views/SettingsWindowView.swift
git commit -m "$(cat <<'EOF'
Resolve custom ZCode hook installs from ~/.zcode or ~/.zcode/cli.

EOF
)"
```

---

## Spec Coverage Checklist

| Spec requirement | Task |
|---|---|
| Profile `zcode-hooks` + path/events/bridge args | Task 1 |
| Nested `hooks.events` + `hooks.enabled = true` on install | Task 2 |
| Preserve foreign hooks / metadata | Task 2 (+ tests in Task 1) |
| Uninstall Island-only; do not force `enabled = false` | Task 2 |
| Detection via nested events | Task 2 |
| Settings Integration visible (`alwaysVisibleInSettings`) | Task 1 |
| Custom Hook dropdown (registry) | Task 1 |
| Custom path `~/.zcode` / `cli` UX | Task 3 |
| AGENTS.md bullet | Task 1 |
| No mascot / IDE / remote | — out of scope |

## Self-Review Notes

- No TBD placeholders.
- `updatedConfigurationData` is the pure path remote + tests already use; disk `updateHooks` / `removeManagedHooks` must stay in sync via the same helpers.
- `createTemporarySettingsFile` remains Claude-flat; only callers today are Claude runtime / temporary-settings tests — leave unchanged (ZCode not used there).
- Prototype `HookInstaller` is a separate simplified type; shipping path is Xcode `PingIsland` — do not dual-port unless a later task requires it.
