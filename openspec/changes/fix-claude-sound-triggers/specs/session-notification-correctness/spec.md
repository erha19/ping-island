## ADDED Requirements

### Requirement: Claude turn-end hook events keep the session alive and waiting for input

The hook payload mapper SHALL translate Claude Code's `Stop`, `StopFailure`, `SubagentStart`, and `SubagentStop` events into session statuses that reflect their per-Anthropic-docs semantics: `Stop` and `StopFailure` mean "the main agent finished its turn and the session is waiting for the next user input", and `SubagentStart` / `SubagentStop` mean "a sub-agent task is starting or finished while the parent session continues processing". Only `SessionEnd` is treated as the session terminating. This rule applies to all clients sharing the `.claude` provider channel (claude-code, codebuddy, codebuddy-cli, qoderwork, qwen-code, hermes, openclaw, workbuddy, kimi); the previous Kimi-only carve-out is replaced by uniform behavior.

#### Scenario: Claude Stop hook produces a waiting-for-input session

- **WHEN** Claude Code emits a `Stop` hook for an active session
- **AND** no other in-flight tool or intervention is pending
- **THEN** the session phase transitions to `.waitingForInput`
- **AND** the session is NOT removed and is NOT marked `.ended`
- **AND** the resulting phase edge is eligible to fire the `taskCompleted` notification sound (subject to existing focus / dedupe gating)

#### Scenario: Claude SubagentStop keeps the parent session processing

- **WHEN** Claude Code emits a `SubagentStop` hook because a `Task` sub-agent completed
- **THEN** the parent session is NOT marked `.ended` and `markSessionEnded` is NOT invoked
- **AND** the parent session phase remains in a "still working" state (`.runningTool` / `.processing`)
- **AND** no `taskCompleted` notification fires solely because of `SubagentStop`

#### Scenario: Claude StopFailure surfaces as ready-for-input with the error attached

- **WHEN** Claude Code emits a `StopFailure` hook (e.g. API rate limit, billing, auth)
- **THEN** the session phase transitions to `.waitingForInput` so the user is alerted instead of seeing a stuck "still working" state
- **AND** the `taskCompleted` sound is eligible to fire on the resulting phase edge
- **AND** the error reason from the payload, if any, is preserved on the session state for the UI to display

#### Scenario: SessionEnd remains the sole terminating event

- **WHEN** Claude Code emits a `SessionEnd` hook
- **THEN** the session is marked `.ended` (preserving the existing UI list-and-archive behavior)
- **AND** any other Stop-family event (`Stop`, `StopFailure`, `SubagentStop`, `SubagentStart`) for the same session does NOT trigger `markSessionEnded`

#### Scenario: Multi-client parity for shared .claude channel

- **WHEN** any client routed through the `.claude` provider channel (codebuddy / codebuddy-cli / qoderwork / qwen-code / hermes / openclaw / workbuddy / kimi) emits `Stop` or `SubagentStop`
- **THEN** the same mapping rules apply uniformly — there is no `if clientKind == "kimi"` carve-out
- **AND** if any one of these clients legitimately needs a different mapping, that client MUST be handled by a documented client-specific branch and called out in the design

### Requirement: Sessions in always-allow mode produce no attention-required sound

When a session has `autoApprovePermissions == true`, the UI sound-edge detector SHALL exclude that session from the `attentionSessions` set used to drive the `attentionRequired` notification sound, in every site where the set is computed. The session remains visible in UI lists and badges as before; only the sound channel is suppressed for it.

#### Scenario: Always-allow session receives multiple PermissionRequests

- **WHEN** a Claude session has `autoApprovePermissions == true`
- **AND** Claude Code fires two consecutive `PermissionRequest` hooks (each auto-approved by `SessionMonitor.handleIncomingHookEvent` via `shouldAutoApproveClaudePermission`)
- **THEN** the `attentionRequired` notification sound fires zero times
- **AND** no other notification sound (`taskCompleted`, `processingStarted`, `taskError`, `resourceLimit`) fires solely as a side effect of the auto-approved request

#### Scenario: Toggling always-allow off restores the attention sound

- **WHEN** a session previously had `autoApprovePermissions == true` and the user toggles it off
- **AND** a new `PermissionRequest` arrives that is NOT auto-approved
- **THEN** the session is once again included in `attentionSessions`
- **AND** the `attentionRequired` sound fires on the resulting phase edge as it would for any non-always-allow session

#### Scenario: SoundManager and edge-detector paths stay aligned

- **WHEN** a session is in always-allow mode and a `PermissionRequest` arrives
- **THEN** both the `SoundManager.shared.handleEvent(...)` path (already gated by `shouldAutoApproveClaudePermission`) and the phase-edge `attentionRequired` path are silent
- **AND** neither path fires under any timing race between `process(.hookReceived)` and `process(.permissionApproved)`

### Requirement: Process-liveness sweep removes orphaned sessions

The session store SHALL run a periodic sweep that removes a session when its tracked Claude process is no longer alive, providing a bounded fallback for the case where the `SessionEnd` hook is never delivered (Ctrl-C kill, OOM, segfault, terminal closed without graceful shutdown). The sweep SHALL also garbage-collect any session that has reached `phase == .ended`. The sweep period SHALL be a small constant (target 5 seconds, MUST NOT exceed 10) and the cost per session SHALL be a single non-blocking `kill(pid, 0)` syscall.

#### Scenario: Crashed Claude process is reaped within one sweep period

- **WHEN** a session has a tracked `pid` and that process is killed externally (e.g. `kill -9` or terminal closed) without delivering a `SessionEnd` hook
- **THEN** within one sweep period the session is removed from the store
- **AND** any pending sync / poll task tied to that session is cancelled
- **AND** the UI session list reflects the removal on the next `publishState`

#### Scenario: Sessions in .ended phase are garbage-collected

- **WHEN** a session has `phase == .ended` (set by `markSessionEnded` from a legitimate `SessionEnd`)
- **AND** any UI logic that depended on the visible `.ended` state has had a chance to act on it
- **THEN** the next sweep removes the session from the store
- **AND** the previously-existing UI behaviors that depend on temporarily seeing `.ended` (archive action, ended-list rendering) continue to work because they observe the state before the sweep removes it

#### Scenario: Live processes are not disturbed

- **WHEN** the sweep runs and a session's tracked `pid` is still alive (`kill(pid, 0) == 0`)
- **AND** the session's phase is not `.ended`
- **THEN** the session is left untouched
- **AND** no other side effect occurs (no extra sync, no phase change, no notification sound)

#### Scenario: Sessions without a known pid are not removed

- **WHEN** a session has no tracked `pid` (e.g., remote-bridge / IDE-hosted clients that never reported one)
- **THEN** the sweep does NOT remove it on liveness grounds (only the `.ended` rule above can remove it)
- **AND** sweep iterations remain O(sessions) regardless of how many lack a pid
