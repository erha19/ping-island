# AGENTS.md

This file is a routing layer for coding agents working in this repo. Keep it short. Put long-lived detail in nearby code, focused docs, or tests.

## Mission

- `PingIsland` is a macOS menu bar app that surfaces Dynamic Island-style status for Claude Code and Codex sessions.
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
- Session bridge for UI: `PingIsland/Services/Session/SessionMonitor.swift`
- Notch state and layout: `PingIsland/Core/NotchViewModel.swift`, `PingIsland/UI/Views/NotchView.swift`
- Claude hook ingress: `PingIsland/Resources/island-state.py`, `PingIsland/Services/Hooks/HookInstaller.swift`, `PingIsland/Services/Hooks/HookSocketServer.swift`
  - `island-state.py` is responsible for terminal, tmux, SSH-remote, and IDE terminal context capture before envelopes hit Swift code
- Codex ingress: `PingIsland/Services/Codex/`, `PingIsland/UI/Views/CodexSessionView.swift`
  - Hook-less fallback parsing for Codex sessions lives in `PingIsland/Services/Codex/CodexRolloutParser.swift`
- Terminal and focus control: `PingIsland/Services/Tmux/`, `PingIsland/Services/Window/`, `PingIsland/Utilities/TerminalVisibilityDetector.swift`
- Provider/client routing: bridge envelopes are normalized in `PingIsland/Services/Hooks/HookSocketServer.swift`, stored on `SessionState`, and launched via `PingIsland/Services/Window/SessionLauncher.swift`
- Client profile registry: installable hook clients and runtime client branding / recognition are centralized in `PingIsland/Models/ClientProfile.swift`
- VS Code-compatible IDE focus extension install / URI launch: `PingIsland/Services/Window/IDEExtensionInstaller.swift`, `PingIsland/Services/Window/TerminalSessionFocuser.swift`
- Session list UI: `PingIsland/UI/Views/SessionListView.swift`

## Repo Map

- `PingIsland/App`: app lifecycle, window setup, screen observation
- `PingIsland/Core`: notch geometry, shared state, app settings, selectors
- `PingIsland/Models`: domain models for sessions, events, tools, phases
- `PingIsland/Services`: ingestion, socket handling, state management, tmux, windows, updates
- `PingIsland/Services/Window/IDEExtensionInstaller.swift`: installs the VS Code-compatible terminal-focus extension used by Cursor / VS Code / CodeBuddy / Qoder style IDE hosts
- `PingIsland/UI`: SwiftUI views, reusable components, AppKit-backed window controllers
- `PingIsland/Resources`: hook assets, entitlements, bundled fonts
- `Prototype`: Swift package prototype and testbed
- `scripts`: release, signing, and packaging automation

## Change Routing

- If you change hook payload shape or hook event semantics, update these together:
  - `PingIsland/Resources/island-state.py`
  - `PingIsland/Services/Hooks/HookSocketServer.swift`
  - `PingIsland/Models/SessionEvent.swift`
  - `PingIsland/Services/State/SessionStore.swift`
  - the affected UI under `PingIsland/UI/`
- If you change provider/client detection or click-through behavior, trace through `HookSocketServer`, `SessionStore`, `SessionState`, `SessionLauncher`, and the session list / hover UI so labels and launch targets stay in sync.
- If you add a Claude-compatible hook client, start in `PingIsland/Models/ClientProfile.swift` and wire any truly client-specific behavior from there before adding new ad-hoc switches elsewhere.
- If you change how sessions are associated across relaunches or between hook/app-server ingress paths, inspect both `SessionStore` and `SessionAssociationStore` so cached client metadata stays compatible.
- If you change session lifecycle or transitions, start in `SessionStore`. Avoid ad-hoc state mutation elsewhere.
  - Current rule: provider-originated end events should preserve the session in `.ended` so it stays visible in the list; only explicit user archive/removal should delete it from `SessionStore`.
- If you change notch sizing, opening behavior, or visibility, inspect both `NotchViewModel` and `NotchView`.
- If you change tmux or terminal focusing, trace through `Services/Tmux`, `Services/Window`, and `TerminalVisibilityDetector`.
- If you change IDE terminal jump behavior, inspect both `TerminalSessionFocuser` and `IDEExtensionInstaller`, plus the integration settings UI so install state and URI schemes stay aligned.
- If you change Codex behavior, verify both the monitor layer under `PingIsland/Services/Codex/` and the UI under `PingIsland/UI/Views/CodexSessionView.swift`.
- If you only need logic-level confidence, prefer adding or updating tests under `Prototype/Tests`.

## Build And Test

- App debug build:
  - `xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug build`
- App release build:
  - `xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Release build`
- Prototype tests:
  - `swift test --package-path Prototype`
- Release automation:
  - `./scripts/build.sh`
  - `./scripts/create-release.sh`
  - `./scripts/generate-keys.sh`
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
- If approval or intervention flows changed, do approve, deny, and answer paths still resolve cleanly?
- If focus logic changed, does tmux and non-tmux behavior still degrade safely?
- If release tooling changed, avoid running notarization or signing steps unless the task explicitly requires them.

## Current Reality

- The main shipping target is the Xcode project, not the Swift package under `Prototype/`.
- `Prototype/Tests` exists, but there is no parallel Xcode app test target in the root project today.
- The worktree may already be dirty. Check `git status` before broad edits.
