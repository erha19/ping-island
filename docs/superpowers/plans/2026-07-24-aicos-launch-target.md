# AI-COS Launch Target Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Settings → Integration pick an already-installed managed hook agent as the AI-COS Mission Pack launch target, then open that agent after copying the protocol prompt (no skill file install).

**Architecture:** Persist one `ManagedHookClientProfile.id` under UserDefaults. A pure resolver maps stored id + installed-profile list → effective target (with Codex-first / first-installed / nil fallback). Generalize `AICOSCodexActivator` into an agent-agnostic activator that focuses matching Island sessions by `profile.brand`, then activates/opens apps from `localAppBundleIdentifiers`. Settings shows a picker of installed agents; the Mission panel uses the resolved title in button/status copy.

**Tech Stack:** Swift / SwiftUI / AppKit (`NSWorkspace`), existing `HookInstaller` + `ClientProfileRegistry`, XCTest (`PingIslandTests`).

**Spec:** `docs/superpowers/specs/2026-07-24-aicos-launch-target-design.md`

## Global Constraints

- Launch-target preference only: never create/remove/symlink files under agent skill directories.
- Dropdown source: all `ManagedHookClientProfile` with `HookInstaller.isInstalled(profile) == true` (no skills-capable whitelist).
- Defaults key: `AICOS.launchTargetProfileID.v1` (string profile id).
- Fallback when unset or stale: `codex-hooks` if installed → else first installed in registry order → else `nil` (copy still succeeds).
- Codex-selected targets may keep the existing `codex://` open fallback.
- Profiles with empty `localAppBundleIdentifiers`: copy OK, activator returns `false`, panel soft-fails.
- Localization: add/update keys in both `en.lproj` and `zh-Hans.lproj`.
- Commits: only when the user explicitly asks; skip commit steps during execution unless requested.
- Do not expand Mission Pack prompt shape per agent in this plan.

---

## File Structure

| File | Role |
|---|---|
| `PingIsland/Models/AICOSMissionModels.swift` | Add `launchTargetProfileIDDefaultsKey`. |
| `PingIsland/Services/AICOS/AICOSLaunchTargetResolver.swift` | Pure resolve / persist helpers for launch target. |
| `PingIsland/Services/AICOS/AICOSCodexActivator.swift` | Generalize to profile-aware activate + preferred session by brand (keep type name or thin typealias if call sites stay short). |
| `PingIsland/UI/Views/SettingsWindowView.swift` | AI-COS launch-target picker under protocol-root row; view-model state. |
| `PingIsland/UI/Views/AICOSMissionPanelView.swift` | Dynamic button/hint/status using resolved target title. |
| `PingIsland/Resources/en.lproj/Localizable.strings` | New format strings. |
| `PingIsland/Resources/zh-Hans.lproj/Localizable.strings` | Matching Chinese strings. |
| `PingIslandTests/AICOSMissionPackBuilderTests.swift` | Resolver + preferred-session-by-brand tests (extend or split file if it grows). |
| `docs/ai-cos-mission-pack.md` | Document launch-target picker. |
| `AGENTS.md` | Only if entrypoint names change materially. |

If the Xcode project uses a synchronized `PingIsland/` group, new Swift files under `Services/AICOS/` are picked up automatically. Otherwise add `AICOSLaunchTargetResolver.swift` to the PingIsland target in `project.pbxproj`.

---

### Task 1: Launch-target resolver + failing tests

**Files:**
- Modify: `PingIsland/Models/AICOSMissionModels.swift`
- Create: `PingIsland/Services/AICOS/AICOSLaunchTargetResolver.swift`
- Modify: `PingIslandTests/AICOSMissionPackBuilderTests.swift`

**Interfaces:**
- Consumes: `ManagedHookClientProfile`, `ClientProfileRegistry.managedHookProfiles`, `UserDefaults`
- Produces:
  - `AICOSMissionConstants.launchTargetProfileIDDefaultsKey == "AICOS.launchTargetProfileID.v1"`
  - `AICOSLaunchTargetResolver.installedProfiles(isInstalled:)` → `[ManagedHookClientProfile]`
  - `AICOSLaunchTargetResolver.resolve(storedProfileID:installed:)` → `ManagedHookClientProfile?`
  - `AICOSLaunchTargetResolver.loadStoredProfileID(defaults:)` / `setStoredProfileID(_:defaults:)`
  - `AICOSLaunchTargetResolver.resolvedProfile(defaults:isInstalled:)` convenience combining load + resolve

- [ ] **Step 1: Write failing resolver tests**

Append to `PingIslandTests/AICOSMissionPackBuilderTests.swift`:

```swift
func testLaunchTargetResolvePrefersStoredWhenInstalled() throws {
    let codex = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "codex-hooks"))
    let zcode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
    let installed = [codex, zcode]
    let resolved = AICOSLaunchTargetResolver.resolve(
        storedProfileID: "zcode-hooks",
        installed: installed
    )
    XCTAssertEqual(resolved?.id, "zcode-hooks")
}

func testLaunchTargetResolveFallsBackToCodexWhenStoredMissing() throws {
    let codex = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "codex-hooks"))
    let zcode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
    let resolved = AICOSLaunchTargetResolver.resolve(
        storedProfileID: "gemini-hooks",
        installed: [zcode, codex]
    )
    XCTAssertEqual(resolved?.id, "codex-hooks")
}

func testLaunchTargetResolveFallsBackToFirstInstalledWithoutCodex() throws {
    let zcode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
    let kimi = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "kimi-hooks"))
    let installed = [zcode, kimi]
    let resolved = AICOSLaunchTargetResolver.resolve(
        storedProfileID: nil,
        installed: installed
    )
    XCTAssertEqual(resolved?.id, "zcode-hooks")
}

func testLaunchTargetResolveReturnsNilWhenNothingInstalled() {
    let resolved = AICOSLaunchTargetResolver.resolve(
        storedProfileID: "codex-hooks",
        installed: []
    )
    XCTAssertNil(resolved)
}

func testLaunchTargetPersistenceRoundTrip() {
    let suiteName = "AICOSLaunchTargetResolverTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertNil(AICOSLaunchTargetResolver.loadStoredProfileID(defaults: defaults))
    AICOSLaunchTargetResolver.setStoredProfileID("zcode-hooks", defaults: defaults)
    XCTAssertEqual(AICOSLaunchTargetResolver.loadStoredProfileID(defaults: defaults), "zcode-hooks")
    AICOSLaunchTargetResolver.setStoredProfileID("", defaults: defaults)
    XCTAssertNil(AICOSLaunchTargetResolver.loadStoredProfileID(defaults: defaults))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug \
  CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/AICOSMissionPackBuilderTests/testLaunchTargetResolvePrefersStoredWhenInstalled
```

Expected: compile error or FAIL because `AICOSLaunchTargetResolver` does not exist yet.

- [ ] **Step 3: Add defaults key**

In `AICOSMissionConstants`:

```swift
static let launchTargetProfileIDDefaultsKey = "AICOS.launchTargetProfileID.v1"
```

- [ ] **Step 4: Implement resolver**

Create `PingIsland/Services/AICOS/AICOSLaunchTargetResolver.swift`:

```swift
import Foundation

enum AICOSLaunchTargetResolver {
    static func installedProfiles(
        from profiles: [ManagedHookClientProfile] = ClientProfileRegistry.managedHookProfiles,
        isInstalled: (ManagedHookClientProfile) -> Bool
    ) -> [ManagedHookClientProfile] {
        profiles.filter(isInstalled)
    }

    static func resolve(
        storedProfileID: String?,
        installed: [ManagedHookClientProfile]
    ) -> ManagedHookClientProfile? {
        if let storedProfileID,
           let match = installed.first(where: { $0.id == storedProfileID }) {
            return match
        }
        if let codex = installed.first(where: { $0.id == "codex-hooks" }) {
            return codex
        }
        return installed.first
    }

    static func loadStoredProfileID(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: AICOSMissionConstants.launchTargetProfileIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func setStoredProfileID(_ profileID: String?, defaults: UserDefaults = .standard) {
        let trimmed = profileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: AICOSMissionConstants.launchTargetProfileIDDefaultsKey)
        } else {
            defaults.set(trimmed, forKey: AICOSMissionConstants.launchTargetProfileIDDefaultsKey)
        }
    }

    static func resolvedProfile(
        defaults: UserDefaults = .standard,
        from profiles: [ManagedHookClientProfile] = ClientProfileRegistry.managedHookProfiles,
        isInstalled: (ManagedHookClientProfile) -> Bool = { HookInstaller.isInstalled($0) }
    ) -> ManagedHookClientProfile? {
        resolve(
            storedProfileID: loadStoredProfileID(defaults: defaults),
            installed: installedProfiles(from: profiles, isInstalled: isInstalled)
        )
    }
}
```

- [ ] **Step 5: Run resolver tests**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug \
  CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/AICOSMissionPackBuilderTests
```

Expected: PASS for the new launch-target tests (existing tests still pass).

- [ ] **Step 6: Commit (only if user asked)**

```bash
git add PingIsland/Models/AICOSMissionModels.swift \
  PingIsland/Services/AICOS/AICOSLaunchTargetResolver.swift \
  PingIslandTests/AICOSMissionPackBuilderTests.swift
git commit -m "$(cat <<'EOF'
Add AI-COS launch-target resolver with install-aware fallback.

EOF
)"
```

---

### Task 2: Profile-aware activator

**Files:**
- Modify: `PingIsland/Services/AICOS/AICOSCodexActivator.swift`
- Modify: `PingIslandTests/AICOSMissionPackBuilderTests.swift`

**Interfaces:**
- Consumes: `ManagedHookClientProfile`, `SessionState.clientInfo.brand`, `SessionLauncher.shared.activate`
- Produces:
  - `AICOSCodexActivator.activate(profile:workspacePath:matchingSessions:workspace:) async -> Bool`
  - `AICOSCodexActivator.preferredSession(profile:workspacePath:sessions:) -> SessionState?`
  - Keep `preferredCodexSession` as a thin wrapper calling `preferredSession` with the Codex profile for source compatibility, or update the existing test to the new API

- [ ] **Step 1: Write failing preferred-session-by-brand test**

```swift
func testPreferredSessionMatchesProfileBrandAndWorkspace() throws {
    let cursor = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "cursor-hooks"))
    let matching = SessionState(
        sessionId: "claude:cursor-a",
        cwd: "/tmp/project-a",
        provider: .claude,
        sessionName: "Cursor A",
        clientInfo: SessionClientInfo.default(for: .claude) // adjust brand if default is not .claude
    )
    // Force brand to match cursor profile (.claude in registry for cursor-hooks).
    var cursorSession = matching
    // If SessionClientInfo allows setting brand, set it to cursor.brand; otherwise construct via available API.

    let other = SessionState(
        sessionId: "codex:thread-b",
        cwd: "/tmp/project-a",
        provider: .codex,
        sessionName: "Codex"
    )

    let preferred = AICOSCodexActivator.preferredSession(
        profile: cursor,
        workspacePath: "/tmp/project-a",
        sessions: [other, cursorSession]
    )
    XCTAssertEqual(preferred?.sessionId, cursorSession.sessionId)
}
```

Implementer note: inspect `SessionClientInfo` initializers in `SessionProvider.swift` / `ClientProfile.swift` and construct a value whose `brand == cursor.brand`. Do not invent fields; use the real API. If constructing a custom brand is awkward, filter-only test with two Codex sessions and a Claude-brand profile expecting `nil` is acceptable as long as brand filtering is covered.

Also add:

```swift
func testPreferredSessionReturnsNilWhenNoBrandMatch() throws {
    let zcode = try XCTUnwrap(ClientProfileRegistry.managedHookProfile(id: "zcode-hooks"))
    let codexOnly = SessionState(
        sessionId: "codex:thread-a",
        cwd: "/tmp/project-a",
        provider: .codex,
        sessionName: "A"
    )
    let preferred = AICOSCodexActivator.preferredSession(
        profile: zcode,
        workspacePath: "/tmp/project-a",
        sessions: [codexOnly]
    )
    // zcode-hooks brand is .claude — not .codex
    XCTAssertNil(preferred)
}
```

- [ ] **Step 2: Run test to verify failure / API missing**

Run the new test method via `xcodebuild … -only-testing:…`. Expected: compile error on `preferredSession`.

- [ ] **Step 3: Generalize activator**

Replace the Codex-hardcoded flow in `AICOSCodexActivator.swift` with:

```swift
enum AICOSCodexActivator {
    static let codexBundleIdentifier = "com.openai.codex"

    @MainActor
    static func activate(
        profile: ManagedHookClientProfile?,
        workspacePath: String,
        matchingSessions: [SessionState] = [],
        workspace: NSWorkspace = .shared
    ) async -> Bool {
        guard let profile else { return false }

        if let session = preferredSession(
            profile: profile,
            workspacePath: workspacePath,
            sessions: matchingSessions
        ) {
            if await SessionLauncher.shared.activate(session) {
                return true
            }
        }

        let bundleIDs = profile.localAppBundleIdentifiers
        guard !bundleIDs.isEmpty else { return false }

        if await activateRunningApp(bundleIdentifiers: bundleIDs, workspace: workspace) {
            return true
        }

        if await openApplication(bundleIdentifiers: bundleIDs, workspace: workspace) {
            return true
        }

        if profile.id == "codex-hooks" {
            guard let url = URL(string: "codex://") else { return false }
            return workspace.open(url)
        }
        return false
    }

    static func preferredSession(
        profile: ManagedHookClientProfile,
        workspacePath: String,
        sessions: [SessionState]
    ) -> SessionState? {
        let normalizedWorkspace = normalizedPath(workspacePath)
        let branded = sessions.filter { $0.clientInfo.brand == profile.brand }
        if !normalizedWorkspace.isEmpty,
           let exact = branded.first(where: { normalizedPath($0.cwd) == normalizedWorkspace }) {
            return exact
        }
        return branded.first
    }

    static func preferredCodexSession(
        workspacePath: String,
        sessions: [SessionState]
    ) -> SessionState? {
        guard let codex = ClientProfileRegistry.managedHookProfile(id: "codex-hooks") else {
            return sessions.first { $0.provider == .codex }
        }
        return preferredSession(profile: codex, workspacePath: workspacePath, sessions: sessions)
    }

    // activateRunningApp / openApplication: first match among bundleIDs
    // (same NSWorkspace patterns as today's Codex helpers)
}
```

Update `preferredCodexSession` callers/tests so brand filtering still returns Codex sessions for the Codex profile.

- [ ] **Step 4: Run AICOS tests**

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug \
  CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/AICOSMissionPackBuilderTests
```

Expected: PASS.

- [ ] **Step 5: Commit (only if user asked)**

```bash
git add PingIsland/Services/AICOS/AICOSCodexActivator.swift \
  PingIslandTests/AICOSMissionPackBuilderTests.swift
git commit -m "$(cat <<'EOF'
Generalize AI-COS activator to open the selected Integration agent.

EOF
)"
```

---

### Task 3: Settings Integration picker

**Files:**
- Modify: `PingIsland/UI/Views/SettingsWindowView.swift` (view model + AI-COS section + optional `AICOSLaunchTargetLine`)
- Modify: `PingIsland/Resources/en.lproj/Localizable.strings`
- Modify: `PingIsland/Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `AICOSLaunchTargetResolver`, `hookInstallationStates` / `isHookInstalled`
- Produces: Settings UI that writes `setStoredProfileID` when the user picks an agent

- [ ] **Step 1: Add localization keys**

`zh-Hans.lproj`:

```
"AI-COS 启动目标" = "AI-COS 启动目标";
"从已安装的集成 Agent 中选择，Mission 复制协议后打开该应用" = "从已安装的集成 Agent 中选择，Mission 复制协议后打开该应用";
"请先在上方安装至少一个 Agent" = "请先在上方安装至少一个 Agent";
"未选择可启动的 Agent" = "未选择可启动的 Agent";
```

`en.lproj`:

```
"AI-COS 启动目标" = "AI-COS Launch Target";
"从已安装的集成 Agent 中选择，Mission 复制协议后打开该应用" = "Choose an installed Integration agent; Mission Pack opens it after copying the protocol";
"请先在上方安装至少一个 Agent" = "Install at least one agent above first";
"未选择可启动的 Agent" = "No launchable agent selected";
```

- [ ] **Step 2: Extend Settings view model**

Near existing AI-COS protocol-root state:

```swift
@Published private(set) var aicosLaunchTargetProfileID: String = ""
@Published private(set) var aicosInstalledLaunchProfiles: [ManagedHookClientProfile] = []

func refreshAICOSLaunchTargetState() {
    let installed = AICOSLaunchTargetResolver.installedProfiles { isHookInstalled($0) }
    aicosInstalledLaunchProfiles = installed
    if let resolved = AICOSLaunchTargetResolver.resolve(
        storedProfileID: AICOSLaunchTargetResolver.loadStoredProfileID(),
        installed: installed
    ) {
        aicosLaunchTargetProfileID = resolved.id
        // Optionally heal stale stored id:
        if AICOSLaunchTargetResolver.loadStoredProfileID() != resolved.id {
            AICOSLaunchTargetResolver.setStoredProfileID(resolved.id)
        }
    } else {
        aicosLaunchTargetProfileID = ""
    }
}

func setAICOSLaunchTargetProfileID(_ profileID: String) {
    AICOSLaunchTargetResolver.setStoredProfileID(profileID)
    refreshAICOSLaunchTargetState()
}
```

Call `refreshAICOSLaunchTargetState()` wherever hooks install state is refreshed (same place as `refreshAICOSProtocolRootState()` / after `refreshHookInstallationStates()`).

- [ ] **Step 3: Add picker UI under AI-COS protocol root**

In the Integration AI-COS block (after `AICOSProtocolRootLine`), add a line:

```swift
AICOSLaunchTargetLine(
    profiles: viewModel.aicosInstalledLaunchProfiles,
    selection: Binding(
        get: { viewModel.aicosLaunchTargetProfileID },
        set: { viewModel.setAICOSLaunchTargetProfileID($0) }
    )
)
```

Implement `AICOSLaunchTargetLine` similarly to `AICOSProtocolRootLine`:

- Title: `AI-COS 启动目标`
- Subtitle: explanation string above
- `Picker` with `ForEach(profiles) { Text(verbatim: $0.title).tag($0.id) }`
- If `profiles.isEmpty`: disable picker, show `请先在上方安装至少一个 Agent`

Match existing Integration spacing / typography; do not invent a new card style.

- [ ] **Step 4: Manual UI check**

Build/run Debug (ad-hoc sign if needed, same as `./scripts/run-debug.sh` or prior local workaround). Open Settings → Integration:

- With zero installed agents: picker disabled + hint
- With one+ installed: can select; relaunch settings / refresh still shows selection
- Uninstall selected agent: selection falls back without crash

- [ ] **Step 5: Commit (only if user asked)**

```bash
git add PingIsland/UI/Views/SettingsWindowView.swift \
  PingIsland/Resources/en.lproj/Localizable.strings \
  PingIsland/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "$(cat <<'EOF'
Add AI-COS launch-target picker from installed Integration agents.

EOF
)"
```

---

### Task 4: Mission panel copy + docs

**Files:**
- Modify: `PingIsland/UI/Views/AICOSMissionPanelView.swift`
- Modify: `PingIsland/Resources/en.lproj/Localizable.strings`
- Modify: `PingIsland/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `docs/ai-cos-mission-pack.md`
- Modify: `AGENTS.md` only if activator / settings entry description should mention launch target

**Interfaces:**
- Consumes: `AICOSLaunchTargetResolver.resolvedProfile()`, `AICOSCodexActivator.activate(profile:…)`
- Produces: dynamic Mission panel strings; docs reflect multi-agent launch

- [ ] **Step 1: Add format-string keys**

`zh-Hans`:

```
"复制协议并打开 %@" = "复制协议并打开 %@";
"将复制 AI-COS %@ 启动词并打开 %@。粘贴一次即可应用协议。" = "将复制 AI-COS %@ 启动词并打开 %@。粘贴一次即可应用协议。";
"已复制 AI-COS %@ 启动词。%@ 已前置 — 粘贴即可开始。" = "已复制 AI-COS %@ 启动词。%@ 已前置 — 粘贴即可开始。";
"启动词已复制，但未能打开 %@。请手动启动后粘贴。" = "启动词已复制，但未能打开 %@。请手动启动后粘贴。";
```

`en`:

```
"复制协议并打开 %@" = "Copy Protocol & Open %@";
"将复制 AI-COS %@ 启动词并打开 %@。粘贴一次即可应用协议。" = "Will copy the AI-COS %@ launch prompt and open %@. Paste once to apply the protocol.";
"已复制 AI-COS %@ 启动词。%@ 已前置 — 粘贴即可开始。" = "Copied AI-COS %@ launch prompt. %@ is frontmost — paste to start.";
"启动词已复制，但未能打开 %@。请手动启动后粘贴。" = "Launch prompt copied, but %@ could not be opened. Start it manually and paste.";
```

Keep old Codex-only keys if still referenced elsewhere; otherwise leave them unused or retarget call sites.

- [ ] **Step 2: Wire panel to resolved profile**

In `AICOSMissionPanelView`:

```swift
private var launchTarget: ManagedHookClientProfile? {
    AICOSLaunchTargetResolver.resolvedProfile()
}

private var launchTargetTitle: String {
    launchTarget?.title
        ?? AppLocalization.string("未选择可启动的 Agent")
}
```

Button label:

```swift
AppLocalization.format("复制协议并打开 %@", launchTargetTitle)
```

Hint / success / failure status: pass `level.displayName` and `launchTargetTitle` into the new format strings.

In `launchMission`:

```swift
let profile = AICOSLaunchTargetResolver.resolvedProfile()
let activated = await AICOSCodexActivator.activate(
    profile: profile,
    workspacePath: "",
    matchingSessions: sessionMonitor.instances
)
```

- [ ] **Step 3: Update `docs/ai-cos-mission-pack.md`**

Replace Codex-only launch description with:

1. Configure protocol root under Settings → Integration → AI-COS 技能路径
2. Choose launch target under AI-COS 启动目标 (installed Integration agents)
3. Island flag → pick L1/L2/L3 → copy protocol & open selected agent

Note explicitly: this does not install skills into agent skill directories.

Update code map if `AICOSLaunchTargetResolver` is listed.

- [ ] **Step 4: Run focused tests + Debug build**

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug \
  CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/AICOSMissionPackBuilderTests

xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
```

Expected: tests PASS; build SUCCEEDED.

- [ ] **Step 5: Commit (only if user asked)**

```bash
git add PingIsland/UI/Views/AICOSMissionPanelView.swift \
  PingIsland/Resources/en.lproj/Localizable.strings \
  PingIsland/Resources/zh-Hans.lproj/Localizable.strings \
  docs/ai-cos-mission-pack.md \
  AGENTS.md \
  docs/superpowers/specs/2026-07-24-aicos-launch-target-design.md \
  docs/superpowers/plans/2026-07-24-aicos-launch-target.md
git commit -m "$(cat <<'EOF'
Wire AI-COS Mission Pack launch to the selected Integration agent.

EOF
)"
```

---

## Spec coverage self-check

| Spec requirement | Task |
|---|---|
| Persist `AICOS.launchTargetProfileID.v1` | Task 1 |
| Dropdown = installed managed hook profiles | Task 3 |
| Empty / stale fallback rules | Task 1 + heal in Task 3 |
| Choosing agent = activation (no separate toggle) | Task 3 |
| Generalize activator; session by brand; bundle ids; Codex URI fallback; CLI soft-fail | Task 2 |
| Mission panel dynamic copy | Task 4 |
| No skill directory writes | Global constraint; no task adds installers |
| Docs update | Task 4 |

## Placeholder / consistency self-check

- Resolver API names are stable across Tasks 1–4 (`resolve`, `setStoredProfileID`, `resolvedProfile`).
- Activator entry is `activate(profile:workspacePath:matchingSessions:workspace:)`.
- No TBD / “add error handling later” left in steps.
- Commit steps gated on explicit user request.
