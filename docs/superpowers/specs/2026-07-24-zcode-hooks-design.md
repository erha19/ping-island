# ZCode Hooks Integration Design

Date: 2026-07-24  
Status: approved (pending user review of written spec)

## Goal

Add Z.ai **ZCode** as a first-class managed hook client in Ping Island Settings → Integration, so install/uninstall correctly targets `~/.zcode/cli/config.json`.

Out of scope for v1: mascot/branding, IDE extension install, remote SSH bootstrap, session-list brand specialization beyond existing Claude-family routing.

## Background

ZCode embeds a Claude Code–compatible agent runtime, but hooks live in ZCode’s own config namespace:

- File: `~/.zcode/cli/config.json`
- Shape:

```json
{
  "hooks": {
    "enabled": true,
    "events": {
      "PreToolUse": [ { "matcher": ".*", "hooks": [ { "type": "command", "command": "..." } ] } ]
    },
    "maxOutputBytes": 32768,
    "timeoutMs": 300000
  }
}
```

Existing Ping Island JSON install logic treats `json["hooks"]` as a flat `eventName → [entries]` map (Claude / Qoder / CodeBuddy style). Writing that shape into ZCode’s file would overwrite or mis-nest `enabled` / `events` and break config.

Observed working event set on a live ZCode install (vibe-island): `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `Stop`. Matchers use `.*`. No `SessionEnd`.

## Approach

**Special-case the `zcode-hooks` profile** in `HookInstaller` (same style as Copilot’s flat entries and Claude’s `statusLine` handling), rather than adding a new generic installation kind.

## Profile

Add to `ClientProfileRegistry.managedHookProfiles`:

| Field | Value |
|---|---|
| `id` | `zcode-hooks` |
| `title` | `ZCode` |
| `subtitle` | Manage `~/.zcode/cli/config.json` with Claude-compatible hooks under `hooks.events` |
| `installationKind` | `.jsonHooks` |
| `alwaysVisibleInSettings` | `true` |
| `defaultEnabled` | `false` |
| `configurationRelativePath` | `.zcode/cli/config.json` |
| `bridgeSource` | `claude` |
| `bridgeExtraArguments` | `--client-kind zcode`, `--client-name ZCode`, `--client-originator ZCode` |
| `brand` | `.claude` |
| Logo | none in v1; `iconSymbolName: "z.square.fill"` |

### Events

Align with the live ZCode / vibe-island event set. Every installed event uses matcher `.*` (regex-style, not Claude’s `*`):

| Event | Template |
|---|---|
| `SessionStart` | `.matcher(".*")` |
| `UserPromptSubmit` | `.matcher(".*")` |
| `PreToolUse` | `.matcher(".*")` |
| `PostToolUse` | `.matcher(".*")` |
| `PostToolUseFailure` | `.matcher(".*")` |
| `PermissionRequest` | `.matcher(".*")`, timeout `86400` |
| `Stop` | `.matcher(".*")` |

Do **not** install `SessionEnd`, `Notification`, `SubagentStop`, or `PreCompact` in v1.

## Installer behavior

### Read / write path

For `profile.id == "zcode-hooks"` in `updateHooks`, `containsManagedHooks`, and the uninstall JSON path:

1. Load root JSON object from the target file (create empty object if missing).
2. Treat the managed event map as `hooks.events` (create `hooks` object if needed).
3. On install:
   - Remove existing Island-managed entries for this profile from each event list.
   - Merge preferred Island entries for the selected events.
   - Set `hooks.enabled = true`.
   - Preserve unrelated keys under `hooks` (`maxOutputBytes`, `timeoutMs`, foreign events/entries).
4. On uninstall:
   - Remove only Island-managed entries from `hooks.events`.
   - Do **not** force `hooks.enabled = false` when events become empty (avoid disabling third-party hooks the user may re-add).
5. Detection of “installed”: Island bridge command present under any `hooks.events` entry list.

Custom Hook Install sheet already lists all `managedHookProfiles`, so `ZCode` appears there automatically and uses the same write path when the user picks a custom base directory.

### Detection / settings visibility

`alwaysVisibleInSettings: true` so Integration always shows ZCode. No auto-install on launch (`defaultEnabled: false`).

## Docs and tests

- Update `AGENTS.md` Change Routing with a short ZCode bullet (config path + nested `hooks.events` + `hooks.enabled`).
- Add focused tests (Prototype and/or `PingIslandTests`) that:
  - Install into a temp `cli/config.json` and assert events land under `hooks.events` with `hooks.enabled == true`.
  - Preserve foreign hooks and non-event hook keys.
  - Uninstall removes only Island-managed entries.
  - `containsManagedHooks` / installed state reads the nested shape.

## Non-goals (v1)

- Dedicated `SessionClientBrand.zcode` / mascot assets
- IDE extension profile
- Remote host bootstrap for ZCode
- Migrating or removing existing non-Island bridges (e.g. vibe-island) automatically beyond normal “Island-managed only” replace rules

## Success criteria

1. Settings → Integration shows **ZCode**.
2. Install writes Island bridge hooks under `~/.zcode/cli/config.json` → `hooks.events`, with `hooks.enabled: true`.
3. Uninstall removes Island entries without wiping foreign hooks or unrelated JSON.
4. “添加自定义 Hook 配置” dropdown includes **ZCode**.
5. Tests cover nested install/uninstall/detection.
`)