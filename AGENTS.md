# AGENTS.md

This file is a routing layer for coding agents working in this repo. Keep it short. Put long-lived detail in nearby code, focused docs, or tests.

## Mission

- `PingIsland` is a macOS menu bar app that surfaces Dynamic Island-style status for Claude Code, Codex, Gemini CLI, Qwen Code, and compatible hook-driven agent sessions.
- The main runtime path is:
  - hook or app-server events
  - monitoring and service layers
  - `SessionStore`
  - `SessionMonitor` and `NotchViewModel`
  - SwiftUI notch UI
- There are two important codepaths:
  - `PingIsland/`: the shipping Xcode app
  - `Prototype/`: a SwiftPM prototype with focused tests and reference implementations

## Start Here

- Product overview: `README.md`
- App entry: `PingIsland/App/PingIslandApp.swift`, `PingIsland/App/AppDelegate.swift`
- Main state hub: `PingIsland/Services/State/SessionStore.swift`
- Session association cache: `PingIsland/Services/State/SessionAssociationStore.swift`
- Native runtime rollout scaffold: `PingIsland/Services/Runtime/`, `PingIsland/Core/FeatureFlags.swift`
- Session bridge for UI: `PingIsland/Services/Session/SessionMonitor.swift`
- Notch state and layout: `PingIsland/Core/NotchViewModel.swift`, `PingIsland/UI/Views/NotchView.swift`
- Global shortcuts and shortcut persistence: `PingIsland/Services/Shared/GlobalShortcutManager.swift`, `PingIsland/Utilities/GlobalShortcut.swift`, `PingIsland/Core/Settings.swift`, `PingIsland/UI/Views/SettingsWindowView.swift`
- Claude hook ingress: `Prototype/Sources/IslandBridge/`, `PingIsland/Services/Hooks/HookInstaller.swift`, `PingIsland/Services/Hooks/HookSocketServer.swift`
  - `PingIslandBridge` is the unified Claude/Codex hook entrypoint and is responsible for terminal, tmux, SSH-remote, and IDE terminal context capture before envelopes hit Swift code
- Codex ingress: `PingIsland/Services/Codex/`, `PingIsland/UI/Views/CodexSessionView.swift`
  - Hook-less fallback parsing for Codex sessions lives in `PingIsland/Services/Codex/CodexRolloutParser.swift`
- Terminal and focus control: `PingIsland/Services/Tmux/`, `PingIsland/Services/Window/`, `PingIsland/Utilities/TerminalVisibilityDetector.swift`
  - Terminal focus flows currently cover iTerm2, Ghostty, Terminal.app, tmux, and IDE-hosted terminals
- Remote SSH forwarding and remote-host management: `PingIsland/Services/Remote/`
  - Remote hosts can bootstrap a bridge on the SSH target, rewrite remote hooks, and attach a bidirectional forwarding channel back into PingIsland
- Provider/client routing: bridge envelopes are normalized in `PingIsland/Services/Hooks/HookSocketServer.swift`, stored on `SessionState`, and launched via `PingIsland/Services/Window/SessionLauncher.swift`
- Client profile registry: installable hook clients and runtime client branding / recognition are centralized in `PingIsland/Models/ClientProfile.swift`
- VS Code-compatible IDE focus extension install / URI launch: `PingIsland/Services/Window/IDEExtensionInstaller.swift`, `PingIsland/Services/Window/TerminalSessionFocuser.swift`
- Session list UI: `PingIsland/UI/Views/SessionListView.swift`
- Client mascot system: `PingIsland/UI/Components/MascotView.swift`, `PingIsland/UI/Views/MascotSettingsView.swift`
- App updates and release notes: `PingIsland/Services/Update/`, `PingIsland/UI/Views/ReleaseNotesWindowView.swift`, `PingIsland/UI/Window/ReleaseNotesWindowController.swift`
- Sparkle build configuration: `Config/App.xcconfig`, `Config/LocalSecrets.xcconfig`, `docs/sparkle-release.md`

## Repo Map

- `PingIsland/App`: app lifecycle, window setup, screen observation
- `PingIsland/Core`: notch geometry, shared state, app settings, selectors
- `PingIsland/Models`: domain models for sessions, events, tools, phases
- `PingIsland/Services`: ingestion, socket handling, state management, tmux, windows, updates
- `PingIsland/Services/Runtime`: isolated native Claude/Codex runtime work. This path should coexist with the current implementation behind feature flags until parity is proven.
- `PingIsland/Services/Remote`: remote endpoint persistence, SSH bootstrap / attach, and remote hook forwarding
- `PingIsland/Services/Update`: Sparkle updater bridge, appcast/release-notes loading, update state publishing
- `PingIsland/Services/Window/IDEExtensionInstaller.swift`: installs the VS Code-compatible terminal-focus extension used by Cursor / VS Code / CodeBuddy / Qoder style IDE hosts (`QoderWork` is hook-only, not an IDE extension host)
- `PingIsland/UI`: SwiftUI views, reusable components, AppKit-backed window controllers
- `PingIsland/Resources`: hook assets, entitlements, bundled fonts
- `Prototype`: Swift package prototype and testbed
- `Prototype/Tests`: logic-level unit tests plus process/socket e2e coverage for `IslandBridge`, hook mapping, and install flows
- `scripts`: release, signing, and packaging automation
- `Config`: checked-in build configuration defaults plus optional local-only secrets overrides

## Change Routing

- If you change hook payload shape or hook event semantics, update these together:
  - `Prototype/Sources/IslandBridge/`
  - `PingIsland/Services/Hooks/HookSocketServer.swift`
  - `PingIsland/Models/SessionEvent.swift`
  - `PingIsland/Services/State/SessionStore.swift`
  - the affected UI under `PingIsland/UI/`
- If you change provider/client detection or click-through behavior, trace through `HookSocketServer`, `SessionStore`, `SessionState`, `SessionLauncher`, and the session list / hover UI so labels and launch targets stay in sync.
- If you add a Claude-compatible hook client, start in `PingIsland/Models/ClientProfile.swift` and wire any truly client-specific behavior from there before adding new ad-hoc switches elsewhere.
  - Gemini CLI hooks are managed through `~/.gemini/settings.json`; its `BeforeTool` / `AfterTool` matchers are regex-based, so use `.*` rather than Claude-style `*`.
  - Qwen Code hooks are managed through `~/.qwen/settings.json`; follow the official Qwen Code hook event names (`PreToolUse`, `PostToolUseFailure`, `Notification`, `Stop`, etc.) and remember that `Notification` matcher values are exact notification types such as `permission_prompt`, `idle_prompt`, and `auth_success`.
  - OpenClaw hooks are managed as a generated internal hook directory under `~/.openclaw/hooks/<hook-name>/` and require the paired enablement entry in `~/.openclaw/openclaw.json`; treat it as a directory-discovery integration, not a JSON hook list.
  - Gemini `Notification` hooks are observability-only in the upstream protocol; do not treat them as actionable approval callbacks unless the bridge grows explicit Gemini response handling.
  - Qoder-family hook installs currently cover both `~/.qoder/settings.json` and `~/.qoderwork/settings.json`; keep their event lists and bridge arguments aligned unless the clients diverge on protocol.
  - OpenCode is managed as a generated plugin file under `~/.config/opencode/plugins/ping-island.js`; treat it as a plugin-based integration, not a JSON hooks file.
  - `QoderWork` should not be added to `ideExtensionProfiles` unless it actually ships VS Code-compatible extension support in the future.
- If you change how sessions are associated across relaunches or between hook/app-server ingress paths, inspect both `SessionStore` and `SessionAssociationStore` so cached client metadata stays compatible.
- If you change the new native runtime rollout path, keep it isolated from the legacy hook/app-server flow. Reuse shared `SessionState`-driven views, but keep runtime orchestration, persistence, and feature gating under `PingIsland/Services/Runtime/` and `PingIsland/Core/FeatureFlags.swift`.
- If you change session lifecycle or transitions, start in `SessionStore`. Avoid ad-hoc state mutation elsewhere.
  - Current rule: provider-originated end events should preserve the session in `.ended` so it stays visible in the list; only explicit user archive/removal should delete it from `SessionStore`.
  - Primary list rule: sessions with no new activity for 30 minutes should auto-hide from the primary list until fresh hook/file/app-server activity updates `lastActivity`; sessions that need manual attention should stay visible.
- If you change notch sizing, opening behavior, or visibility, inspect both `NotchViewModel` and `NotchView`.
- If you change global shortcuts, shortcut persistence, or shortcut hints, trace through `PingIsland/Services/Shared/GlobalShortcutManager.swift`, `PingIsland/Utilities/GlobalShortcut.swift`, `PingIsland/Core/Settings.swift`, `PingIsland/UI/Views/SettingsWindowView.swift`, `PingIsland/UI/Components/GlobalShortcutHintView.swift`, and the relevant notch/chat/session-list views together so registration, customization, and visible hints stay aligned.
- If you change built-in notification sounds or startup audio, inspect `PingIsland/Core/Settings.swift`, `PingIsland/Core/SoundPackCatalog.swift`, `PingIsland/UI/Views/SettingsWindowView.swift`, `PingIsland/App/AppDelegate.swift`, and `PingIsland/Resources/Sounds/` together so mode selection, fixed mappings, previews, and bundled assets stay aligned.
- If you change client mascot selection or mascot animations, trace through `PingIsland/Models/ClientProfile.swift`, `PingIsland/Core/Settings.swift`, `PingIsland/UI/Components/MascotView.swift`, and the mascot callsites in `NotchView`, `SessionListView`, `SessionHoverPreviewView`, and `MascotSettingsView` so runtime overrides and previews stay aligned.
- If you change completion-result popup behavior, trace through `SessionStore`, `SessionMonitor`, `PingIsland/UI/Views/NotchView.swift`, and `PingIsland/UI/Views/SessionCompletionNotificationView.swift` so completion detection, queueing, and auto-dismiss timing stay aligned.
- If you change tmux or terminal focusing, trace through `Services/Tmux`, `Services/Window`, and `TerminalVisibilityDetector`.
- If you change IDE terminal jump behavior, inspect both `TerminalSessionFocuser` and `IDEExtensionInstaller`, plus the integration settings UI so install state and URI schemes stay aligned.
- If you change Codex behavior, verify both the monitor layer under `PingIsland/Services/Codex/` and the UI under `PingIsland/UI/Views/CodexSessionView.swift`.
- If you change app updates or release notes, trace through `PingIsland/Services/Update/`, `PingIsland/Info.plist`, the settings UI, and `scripts/create-release.sh` so appcast assets, runtime config, and update messaging stay aligned.
- If you change Sparkle configuration keys or hosting assumptions, update `Config/App.xcconfig`, `Config/LocalSecrets.example.xcconfig`, `scripts/generate-keys.sh`, and `docs/sparkle-release.md` together.
- If you only need logic-level confidence, prefer adding or updating tests under `Prototype/Tests`.

## Build And Test

- Full repo regression:
  - `./scripts/test.sh`
- App debug build:
  - `xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug build`
- App release build:
  - `xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Release build`
- Root Xcode unit tests:
  - `xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests`
- Root Xcode UI tests:
  - `xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGN_IDENTITY=- test -only-testing:PingIslandUITests`
  - macOS may block the UI test runner until a valid local signing identity is available; if `PingIslandUITests-Runner` stays launch-suspended, inspect `amfid` and `AppleSystemPolicy` logs before treating it as an app regression
- Prototype tests:
  - `swift test --package-path Prototype`
- Bridge-focused e2e slice:
  - `swift test --package-path Prototype --filter IslandBridgeE2ETests`
- Mascot GIF export for docs/resources:
  - `./scripts/render-mascots.sh`
- Release automation:
  - `./scripts/build.sh`
  - `./scripts/package-release.sh`
  - `./scripts/package-unsigned.sh`
  - `./scripts/create-release.sh`
  - `./scripts/generate-keys.sh`
  - GitHub Actions: `.github/workflows/release-packages.yml` imports a Developer ID certificate from repository secrets, notarizes the exported app, publishes signed `dmg` / `zip` assets plus a Linux `PingIslandBridge` remote-agent binary to the matching GitHub Release for a `v*` tag or manual dispatch, and should treat the DMG as the primary manual-install artifact
- Release scripts assume local signing and notarization tooling. They may modify `build/`, `releases/`, and `.sparkle-keys/`.

## Working Rules

- Respect existing uncommitted changes. Do not revert unrelated work.
- Prefer narrow edits. This repo currently has active changes in UI and session-flow files.
- Treat documentation upkeep as part of the change, not follow-up work.
- Every major feature change or refactor must review and update `AGENTS.md` plus any affected adjacent docs, tests, scripts, or inline code comments that describe the old behavior.
- Prefer code search over guesswork:
  - `rg "process\\(" PingIsland`
  - `rg "Hook|hook" PingIsland`
  - `rg "Codex" PingIsland Prototype`
  - `rg "tmux|Tmux" PingIsland`
- When adding new state, decide deliberately whether it belongs in:
  - SwiftUI view-local `@State`
  - shared `ObservableObject` state
  - actor-owned `SessionStore` state
- When adding bundled assets or fonts, make sure app startup initializes them.
- Keep this file high-signal. If a section becomes long, move the durable detail into a dedicated markdown doc and link it here.

## Verification Checklist

- Can the main Xcode scheme still build?
- If the change is a major feature or refactor, was `AGENTS.md` reviewed and updated to reflect the new structure, ownership, entrypoints, or verification steps?
- If session ingestion changed, do both Claude and Codex sessions still appear and update?
- If session lifecycle changed, do ended sessions remain visible until the user archives them, and do final Claude/Codex messages still land before the row settles into `.ended`?
- If idle-session visibility changed, do sessions auto-hide after 30 minutes of inactivity and reappear when a new message or hook/app-server event arrives?
- If approval or intervention flows changed, do approve, deny, and answer paths still resolve cleanly?
- If focus logic changed, does tmux and non-tmux behavior still degrade safely?
- If release tooling changed, avoid running notarization or signing steps unless the task explicitly requires them.

## Current Reality

- The main shipping target is the Xcode project, not the Swift package under `Prototype/`.
- The root project now includes `PingIslandTests` and `PingIslandUITests` targets for app-level state and settings-window coverage.
- `Prototype/Tests` remains the fastest place for logic-level unit tests plus process/socket e2e coverage.
- Sparkle update discovery is expected to use the GitHub Releases `latest/download/appcast.xml` asset unless a local override explicitly replaces it.
- The worktree may already be dirty. Check `git status` before broad edits.
