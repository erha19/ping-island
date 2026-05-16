## Why

Three independent defects on the Claude Code event → session phase → notification sound chain are silently degrading the app's core "tell me when Claude needs me" experience: the task-completion sound never fires for Claude users, sub-agent completion can mark the parent session as ended, and a session that has opted into Always-Allow still rings the attention sound on every auto-approved permission. A 2.3k-star reference implementation (`farouqaldori/vibe-notch`) confirms the correct semantics for the first two; the third is unique to our multi-channel sound architecture. While we are auditing this chain we also borrow vibe-notch's process-liveness fallback so a crashed Claude process eventually drops out of the session list even if its `SessionEnd` hook never fires.

## What Changes

- Rewrite `HookPayloadMapper.detectStatus` Stop/SubagentStop/StopFailure branch so Claude (and every other shared `.claude` provider client) maps these events to the correct turn-end / processing semantics instead of falling through to `.completed` → `"ended"`. Removes the existing `clientKind == "kimi"` carve-out (folded into the default behavior).
- Stop the `attentionRequired` sound from firing on `PermissionRequest` events when the session has `autoApprovePermissions == true`, by guarding the `attentionSessions` filter in both UI sites that drive sound edges (`NotchView` and `DetachedIslandWindowController`).
- Add a periodic process-liveness sweep in `SessionStore` that uses `kill(pid, 0)` (and treats `phase == .ended` as garbage-collectable) so sessions whose Claude process crashed or whose `SessionEnd` hook was skipped (Ctrl-C kill, OOM, etc.) get cleaned up within a bounded interval.
- Add regression tests for: (a) Claude `Stop` → `.waitingForInput` and `taskCompleted` sound firing on the resulting phase edge, (b) Claude `SubagentStop` keeping the parent session alive, (c) `autoApprovePermissions` sessions producing zero `attentionRequired` sound edges across multiple PermissionRequest events, (d) liveness sweep removing a session whose pid no longer exists.

## Capabilities

### New Capabilities
- `session-notification-correctness`: Defines the contract between hook events and notification sound edges — which events advance which phases, which phase edges produce which sounds, and which sessions are excluded from sound triggering. Also specifies the process-liveness fallback that keeps the session set bounded when hooks are missed.

### Modified Capabilities
_None_ — `island-8bit-sound-customization` only governs which sound asset plays for each `NotificationEvent`, not when the event fires; this change does not touch its requirements.

## Impact

- **Code (modify)**:
  - `Prototype/Sources/IslandShared/HookPayloadMapper.swift` — `detectStatus` Stop/SubagentStop/StopFailure branch (drops Kimi-only carve-out)
  - `PingIsland/UI/Views/NotchView.swift` and `PingIsland/UI/Window/DetachedIslandWindowController.swift` — `attentionSessions` filter
  - `PingIsland/Services/State/SessionStore.swift` — new periodic liveness sweep + scheduling
  - `PingIslandTests/` — new tests for each fix
- **Hook event semantics (downstream impact)**: Stop/SubagentStop/StopFailure that previously triggered `markSessionEnded(...)` for any non-Kimi `.claude` provider client (codebuddy, codebuddy-cli, qoderwork, qwen-code, hermes, openclaw, workbuddy) will no longer do so. Risk evaluated in `design.md`; verified safe per client.
- **No API / persistence / settings schema changes**. No user-visible setting changes. No new dependencies.
- **Performance**: liveness sweep is a per-session `kill(pid, 0)` syscall on a 5–10 s timer; negligible.
