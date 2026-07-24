# AI-COS Launch Target Design

Date: 2026-07-24  
Status: approved

## Goal

Let the user pick which **already-installed Integration agent** AI-COS Mission Pack should open after copying the protocol prompt.

This is a thin preference + activator extension. It does **not** install, copy, or symlink skills into agent skill directories.

## Background

Today AI-COS Mission Pack always:

1. builds a paste-ready protocol prompt
2. copies it to the clipboard
3. opens / focuses Codex (`com.openai.codex`) via `AICOSCodexActivator`

Settings → Integration already tracks per-profile hook install state (`HookInstaller.isInstalled`). Users expect the AI-COS “activation” target to come from that same installed list, as a dropdown.

Related product decision: multi-agent **skill mounting** (symlink/copy from one AI-COS center) stays out of Ping Island core; users who need that keep doing it outside the app. Island only chooses **which app to bring forward** after copy.

## Approach

**Option 2 — launch-target preference only.**

- Persist one selected managed hook profile id as the AI-COS launch target.
- Dropdown options = Integration profiles with hooks currently installed.
- Mission Pack launch uses that profile’s local app bundle id(s) instead of hard-coding Codex.
- No disk writes under `~/.codex/skills`, `~/.claude/skills`, etc.

## UI

### Settings → Integration → AI-COS

Keep the existing **AI-COS 技能路径** row.

Add:

| Control | Behavior |
|---|---|
| Agent picker (dropdown / `Picker`) | Lists `ManagedHookClientProfile` where `HookInstaller.isInstalled(profile) == true`, titles from `profile.title` |
| Empty state | If none installed: picker disabled, short hint to install an agent above |
| Stale selection | If stored profile id is no longer installed: fall back to default (Codex if installed, else first installed, else none) and refresh UI |

No separate “激活 / 取消激活” toggle in v1: **choosing the agent is the activation**. Clearing back to default is enough.

### Island Mission Panel

- Button copy changes from Codex-only wording to the selected agent title when known (e.g. “复制协议并打开 ZCode”), with a Codex-oriented fallback when unset / unavailable.
- Behavior unchanged aside from which app is activated after clipboard write.

## Persistence

| Key | Value |
|---|---|
| `AICOS.launchTargetProfileID.v1` | `String` managed hook profile id (e.g. `codex-hooks`, `zcode-hooks`) |

Unset / empty ⇒ default target resolution:

1. `codex-hooks` if installed
2. else first installed managed hook profile (stable registry order)
3. else no app launch (still copy prompt; surface a soft failure / status)

Protocol root key remains `AICOS.protocolRootPath.v1`.

## Activation behavior

Rename / generalize `AICOSCodexActivator` into an agent-agnostic activator (keep a thin Codex-named wrapper only if call sites need a short migration), e.g. `AICOSLaunchTargetActivator`.

Given selected `ManagedHookClientProfile`:

1. Prefer focusing an existing Island session whose provider/client matches that profile’s brand / bridge identity and whose `cwd` matches the mission workspace when possible.
2. Else activate a running app whose `bundleIdentifier` is in `profile.localAppBundleIdentifiers`.
3. Else `NSWorkspace.openApplication` for the first resolvable bundle id on the profile.
4. If the profile has **no** `localAppBundleIdentifiers` (CLI-only / config-only clients): copy still succeeds; activator returns failure and the panel shows that the prompt was copied but no GUI app could be opened.

Do not invent new URI schemes in v1 beyond what a profile already implies. Codex may keep its existing `codex://` fallback when the selected profile is Codex.

## Filtering

v1 dropdown = **all installed managed hook profiles**, not a skills-capable whitelist.

Rationale: user explicitly asked to read Integration’s installed agents. Profiles without a GUI bundle still appear; launch may only copy + show the soft failure above.

## Out of scope (v1)

- Symlink / copy of AI-COS files into agent skill directories
- Multi-target activation (one agent only)
- Auto-inject prompt into agent threads / app-server
- Changing protocol pack text shape based on target agent
- Remote SSH skill or launch-target management
- New telemetry beyond existing patterns unless trivial

## Code map (expected touch)

| Piece | Path |
|---|---|
| Models / defaults keys | `PingIsland/Models/AICOSMissionModels.swift` |
| Catalog + launch-target resolve | `PingIsland/Services/AICOS/` |
| Activator | generalize `AICOSCodexActivator.swift` |
| Settings UI | `SettingsWindowView` AI-COS Integration section |
| Mission panel copy / launch | `AICOSMissionPanelView.swift` |
| Docs | `docs/ai-cos-mission-pack.md`, `AGENTS.md` if entrypoints change |
| Tests | resolve defaults / stale selection / preferred session matching |

## Success criteria

- User with at least one installed Integration agent can pick it from the AI-COS dropdown.
- Mission Pack copies the same protocol prompt as today and brings that agent’s GUI app forward when a bundle id exists.
- Uninstalling the selected agent does not crash; selection falls back per rules above.
- No skill files are created or removed under agent home directories.
