# AGENTS.md

This file is a routing layer for coding agents working in this repo. Keep it short. Put long-lived detail in nearby code, focused docs, or tests.

## Mission

- `ClaudeIsland` is a macOS menu bar app that surfaces Dynamic Island-style status for Claude Code and Codex sessions.
- The main runtime path is:
  - hook or app-server events
  - monitoring and service layers
  - `SessionStore`
  - `ClaudeSessionMonitor` and `NotchViewModel`
  - SwiftUI notch UI
- There are two important codepaths:
  - `ClaudeIsland/`: the shipping Xcode app
  - `Prototype/`: a SwiftPM prototype with focused tests and reference implementations

## Start Here

- Product overview: `README.md`
- App entry: `ClaudeIsland/App/ClaudeIslandApp.swift`, `ClaudeIsland/App/AppDelegate.swift`
- Main state hub: `ClaudeIsland/Services/State/SessionStore.swift`
- Session association cache: `ClaudeIsland/Services/State/SessionAssociationStore.swift`
- Session bridge for UI: `ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift`
- Notch state and layout: `ClaudeIsland/Core/NotchViewModel.swift`, `ClaudeIsland/UI/Views/NotchView.swift`
- Claude hook ingress: `ClaudeIsland/Resources/island-state.py`, `ClaudeIsland/Services/Hooks/HookInstaller.swift`, `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
  - `island-state.py` is responsible for terminal, tmux, SSH-remote, and IDE terminal context capture before envelopes hit Swift code
- Codex ingress: `ClaudeIsland/Services/Codex/`, `ClaudeIsland/UI/Views/CodexSessionView.swift`
  - Hook-less fallback parsing for Codex sessions lives in `ClaudeIsland/Services/Codex/CodexRolloutParser.swift`
- Terminal and focus control: `ClaudeIsland/Services/Tmux/`, `ClaudeIsland/Services/Window/`, `ClaudeIsland/Utilities/TerminalVisibilityDetector.swift`
- Provider/client routing: bridge envelopes are normalized in `ClaudeIsland/Services/Hooks/HookSocketServer.swift`, stored on `SessionState`, and launched via `ClaudeIsland/Services/Window/SessionLauncher.swift`
- Client profile registry: installable hook clients and runtime client branding / recognition are centralized in `ClaudeIsland/Models/ClientProfile.swift`
- VS Code-compatible IDE focus extension install / URI launch: `ClaudeIsland/Services/Window/IDEExtensionInstaller.swift`, `ClaudeIsland/Services/Window/TerminalSessionFocuser.swift`

## Repo Map

- `ClaudeIsland/App`: app lifecycle, window setup, screen observation
- `ClaudeIsland/Core`: notch geometry, shared state, app settings, selectors
- `ClaudeIsland/Models`: domain models for sessions, events, tools, phases
- `ClaudeIsland/Services`: ingestion, socket handling, state management, tmux, windows, updates
- `ClaudeIsland/Services/Window/IDEExtensionInstaller.swift`: installs the VS Code-compatible terminal-focus extension used by Cursor / VS Code / Trae / CodeBuddy style IDE hosts
- `ClaudeIsland/UI`: SwiftUI views, reusable components, AppKit-backed window controllers
- `ClaudeIsland/Resources`: hook assets, entitlements, bundled fonts
- `Prototype`: Swift package prototype and testbed
- `scripts`: release, signing, and packaging automation

## Change Routing

- If you change hook payload shape or hook event semantics, update these together:
  - `ClaudeIsland/Resources/island-state.py`
  - `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
  - `ClaudeIsland/Models/SessionEvent.swift`
  - `ClaudeIsland/Services/State/SessionStore.swift`
  - the affected UI under `ClaudeIsland/UI/`
- If you change provider/client detection or click-through behavior, trace through `HookSocketServer`, `SessionStore`, `SessionState`, `SessionLauncher`, and the session list / hover UI so labels and launch targets stay in sync.
- If you add a Claude-compatible hook client, start in `ClaudeIsland/Models/ClientProfile.swift` and wire any truly client-specific behavior from there before adding new ad-hoc switches elsewhere.
- If you change how sessions are associated across relaunches or between hook/app-server ingress paths, inspect both `SessionStore` and `SessionAssociationStore` so cached client metadata stays compatible.
- If you change session lifecycle or transitions, start in `SessionStore`. Avoid ad-hoc state mutation elsewhere.
  - Current rule: provider-originated end events should preserve the session in `.ended` so it stays visible in the list; only explicit user archive/removal should delete it from `SessionStore`.
- If you change notch sizing, opening behavior, or visibility, inspect both `NotchViewModel` and `NotchView`.
- If you change tmux or terminal focusing, trace through `Services/Tmux`, `Services/Window`, and `TerminalVisibilityDetector`.
- If you change IDE terminal jump behavior, inspect both `TerminalSessionFocuser` and `IDEExtensionInstaller`, plus the integration settings UI so install state and URI schemes stay aligned.
- If you change Codex behavior, verify both the monitor layer under `ClaudeIsland/Services/Codex/` and the UI under `ClaudeIsland/UI/Views/CodexSessionView.swift`.
- If you only need logic-level confidence, prefer adding or updating tests under `Prototype/Tests`.

## Build And Test

- App debug build:
  - `xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -configuration Debug build`
- App release build:
  - `xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland -configuration Release build`
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
  - `rg "process\\(" ClaudeIsland`
  - `rg "Hook|hook" ClaudeIsland`
  - `rg "Codex" ClaudeIsland Prototype`
  - `rg "tmux|Tmux" ClaudeIsland`
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
