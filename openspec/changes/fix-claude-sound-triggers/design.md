## Context

Three independent defects landed on the same chain — Claude Code hook events flow through `HookPayloadMapper.detectStatus` (`Prototype/Sources/IslandShared/HookPayloadMapper.swift:348`) into a wire status string via `mapStatus` (`Prototype/Sources/IslandBridge/main.swift:1082` and `PingIsland/Services/Hooks/HookSocketServer.swift:613`), are decoded by `HookEvent` (`PingIsland/Models/SessionEvent.swift:619`) into a `SessionPhase`, then drive UI sound edges in `NotchView` (`PingIsland/UI/Views/NotchView.swift:1264-1308`) and `DetachedIslandWindowController` (`PingIsland/UI/Window/DetachedIslandWindowController.swift:1677-1721`). Each defect lives at a different layer of that chain:

1. **Stop / SubagentStop / StopFailure mis-mapping** — `detectStatus` lines 400-408 currently fall through to `.completed` for every Stop-family event (the only carve-out is `clientKind == "kimi"` for `Stop`). `.completed` becomes the wire string `"ended"`, which `SessionStore.processHookEvent` (line 449) feeds into `markSessionEnded`. For Claude this means the `taskCompleted` sound — gated by `isCompletedReadySession` (`PingIsland/UI/Views/SessionCompletionNotificationView.swift:121`, requires `phase == .waitingForInput`) — never has a chance to fire, and the parent session is killed when any sub-agent finishes.
2. **Always-allow sessions still ring `attentionRequired`** — `SessionMonitor.handleIncomingHookEvent` (`PingIsland/Services/Session/SessionMonitor.swift:143-176`) gates the legacy `SoundManager.shared.handleEvent(...)` path on `shouldAutoApproveClaudePermission`, but the second sound channel — phase-edge detection in `NotchView`/`DetachedIslandWindowController` — has no such guard. The `attentionSessions` filter only checks `needsApprovalResponse || (phase == .waitingForInput && intervention != nil)`, ignoring `autoApprovePermissions`. Every `PermissionRequest` therefore briefly inserts the session into `attentionSessions`, fires the sound, then gets cleaned up by the subsequent `permissionApproved` event.
3. **Sessions can outlive their Claude process** — when a Claude process is killed without delivering a `SessionEnd` hook (Ctrl-C, OOM, terminal closed), the session sits in the store indefinitely. The 2.3k-star `farouqaldori/vibe-notch` reference implementation runs a 3-second `kill(pid, 0)` liveness sweep (`SessionStore.swift:1050-1109` in their tree); we have no equivalent.

We confirmed Claude semantics by reading both the Anthropic hook docs in this conversation and the vibe-notch implementation directly (`/Users/touboku/git/vibe-notch/ClaudeIsland/Resources/claude-island-state.py:193-215` and `ClaudeIsland/Services/State/SessionStore.swift:144-176`). Their model maps `Stop → "waiting_for_input"`, `SubagentStop → "processing"`, `SessionEnd → "ended"` (which they handle by `removeValue` rather than a `.ended` phase) — and they have shipped this for 5+ months with no regression.

## Goals / Non-Goals

**Goals:**
- Restore Claude Code's `taskCompleted` sound by mapping `Stop` to `.waitingForInput` instead of `.ended`.
- Stop `SubagentStop` from killing the parent session.
- Stop the `attentionRequired` sound from firing on auto-approved `PermissionRequest` events.
- Add a bounded-cost periodic sweep that removes orphaned sessions whose process is no longer alive.
- Remove the `clientKind == "kimi"` special case so the multi-CLI surface is uniform.

**Non-Goals:**
- We will NOT delete the `.ended` phase or change `markSessionEnded`'s contract — `SessionListView` (line 519), `SessionState.shouldShowArchiveActionInPrimaryUI` (line 1073), and other UI sites depend on briefly seeing `.ended` before sweep cleanup. (vibe-notch's "remove immediately on SessionEnd" simplification is incompatible with our archive UX.)
- We will NOT introduce a new global throttle / time-window dedupe. Phase-edge detection plus the per-state `previous*Ids` set has been adequate; we keep that model.
- We will NOT add `StopFailure` hook registration in this change. Anthropic shipped the event later than our installer (`HookInstaller.swift:437` and `:506`); registering it is its own coordinated change with hook-template churn. The mapping rule in this change is pre-emptive — it ensures correct behavior if and when the hook is registered.
- We will NOT touch `island-8bit-sound-customization` requirements. That capability governs which asset plays per `NotificationEvent`; this change governs which event fires.

## Decisions

### Decision 1: Rewrite `detectStatus` Stop branch to a name-keyed switch instead of a contains-driven fall-through

`HookPayloadMapper.swift:400-408` becomes:

```swift
if lowered.contains("stop") || lowered.contains("end") {
    switch lowered {
    case "sessionend":
        return SessionStatus(kind: .completed)            // → "ended" → markSessionEnded
    case "subagentstart", "subagentstop":
        return SessionStatus(kind: .runningTool)          // parent stays processing
    case "stop", "stopfailure":
        return SessionStatus(kind: .waitingForInput)      // turn ended, ready for user
    default:
        return SessionStatus(kind: .completed)            // unknown stop/end → conservative
    }
}
```

**Why this shape**:
- A name-keyed switch makes the mapping obvious and grep-able; the existing `.lowered.contains(...)` fall-through hides the bug.
- Removes the `clientKind == "kimi"` carve-out at the same line — Kimi's behavior is now the default behavior for everyone, which is what the original Kimi comment (lines 401-403) said the model *should* be.
- Default-case stays `.completed` so any future stop/end variant we don't recognize is conservatively treated as ended (no surprise "session vanished" but also no surprise "session won't end").

**Alternatives considered**:
- **A: Add a per-clientKind table** — we currently have eight clients sharing the `.claude` channel. Per-client tables are fragile and the risk audit (below) showed none of them actually need different behavior.
- **B: Move the translation entirely into the hook script (vibe-notch's approach)** — vibe-notch translates in the Python hook script before sending across the socket. Our architecture puts the translation in the Swift bridge so a single mapper handles every CLI. Moving it would be a much larger refactor for no incremental win.
- **C: Patch downstream (`markSessionEnded` to ignore SubagentStop)** — fixes a symptom, leaves the wrong status in flight, and leaks into other consumers (`SessionStore.swift:1772`, `:2446`, `:2523` all branch on `event.status == "ended"`).

### Decision 2: Guard `attentionSessions` filter with `!autoApprovePermissions` at every site

Apply the same single-line guard to `NotchView.swift:1267-1269` and `DetachedIslandWindowController.swift:1680-1682`:

```swift
let attentionSessions = instances.filter { session in
    guard !session.autoApprovePermissions else { return false }
    return session.needsApprovalResponse
        || (session.phase == .waitingForInput && session.intervention != nil)
}
```

**Why at the UI filter (not at the SessionStore source)**:
- Symmetry with the existing gate — `SessionMonitor.swift:153` already uses the *same* boolean to mute the SoundManager path. UI-side mirroring is the smallest delta.
- `intervention` and `needsApprovalResponse` still genuinely toggle on/off across the auto-approve flow (they are used by the badge / list / hover preview UI for the brief moment the request is in flight). Suppressing them at SessionStore would require deeper surgery in `SessionState` and risk breaking those UI affordances.
- The badge / list still flicker briefly during auto-approval; we accept that as visual noise without an audible component, which matches the user's mental model of "auto-approve = don't bother me but show what happened".

**Alternatives considered**:
- **A: Synchronous auto-approve before `process(.hookReceived)`** — would prevent the intervention from ever appearing. Requires re-ordering `SessionMonitor.handleIncomingHookEvent`, changing the contract of `SessionStore.process`, and threading a "this event will be auto-approved" flag through `HookEvent`. Larger blast radius, fragile.
- **B: New `SessionEvent` case `.hookReceivedAutoApprove`** — same idea, schema-level. Would propagate to many test fixtures.
- **C: Introduce a time-window throttle on `attentionRequired`** — addresses the symptom (rapid edges) but not the root (we should not be edging at all here). Throws away signal in the legitimate non-auto case.

### Decision 3: Periodic liveness sweep in `SessionStore` modeled after vibe-notch

Add to `PingIsland/Services/State/SessionStore.swift`:

```swift
private var livenessTask: Task<Void, Never>?
private let livenessIntervalNs: UInt64 = 5_000_000_000   // 5 s

func startLivenessSweep() {
    guard livenessTask == nil else { return }
    livenessTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { break }
            await self?.sweepDeadOrEndedSessions()
        }
    }
}

func stopLivenessSweep() {
    livenessTask?.cancel()
    livenessTask = nil
}

private func sweepDeadOrEndedSessions() {
    var removed = false
    for (sessionId, session) in Array(sessions) {
        let endedReap = session.phase == .ended
        let liveCheck: Bool = {
            guard let pid = session.pid else { return true }   // unknown pid → keep
            return kill(Int32(pid), 0) == 0
        }()
        if endedReap || !liveCheck {
            sessions.removeValue(forKey: sessionId)
            cancelPendingSync(sessionId: sessionId)            // and any other per-session task
            removed = true
        }
    }
    if removed {
        publishState()
    }
}
```

**Why 5 s instead of vibe-notch's 3 s**:
- Our session list is multi-CLI and may be larger; 5 s halves the syscall volume at the cost of perceived staleness. The interval is tunable; the spec says ≤10 s.

**Why both `.ended` and pid checks in the same sweep**:
- They're the same kind of work (garbage-collect a session that's no longer relevant). Keeping them in one pass keeps the cost flat.
- `.ended` reap is essential because, post-fix, `Stop` no longer transitions to `.ended` — the only way into `.ended` is `SessionEnd` (or future `SessionMonitor`-issued `markSessionEnded`). UI components that read `.ended` (archive action, ended-list rendering) get exactly one publish-state in which to react before reap.

**Why we keep the `.ended` phase at all** (not the vibe-notch `removeValue`-on-arrival approach):
- `SessionState.swift:1073` (`shouldShowArchiveActionInPrimaryUI`) and `SessionListView.swift:519` need a "post-end visible window" to show the archive affordance and ended-list entry. vibe-notch's UI has neither. Keeping `.ended` + delayed reap is the minimal compromise.

**Where to start it**:
- Same lifecycle as `SessionMonitor.startMonitoring()` — start when `SessionMonitor` starts, stop when it stops. The sweep is an actor-internal task on `SessionStore`; it does not race with `process(...)` mutations because `SessionStore` is an actor.

## Risks / Trade-offs

[**Risk**: Some shared-`.claude` client genuinely uses `Stop` to mean "session closed" and will now stay alive indefinitely.] → **Mitigation**: Audit before merge. Per `ClientProfile.swift` and `HookInstaller.swift:437,506`, the clients sharing `.claude`-style hook installation are: claude-code, codebuddy, codebuddy-cli, qoderwork, qwen-code, hermes, openclaw, workbuddy, kimi. (a) Kimi's existing carve-out documents the intended semantics. (b) Hermes (`SessionEvent.swift:665`) only uses `Stop` as a file-sync trigger, not a session-close signal. (c) qoderwork/qwen-code/codebuddy/codebuddy-cli all run their own `SessionEnd` registration paths (`HookInstaller.swift:342`, `:437`, `:506` install `SessionEnd` plain-event templates), so `Stop` was never the close signal. (d) openclaw/workbuddy use the Claude installer family the same way. The new liveness sweep also catches any genuinely-stuck session as a safety net. We will document this audit at the top of the implementation PR description.

[**Risk**: The periodic sweep removes a `.ended` session before some downstream consumer has a chance to react, breaking the archive action.] → **Mitigation**: 5 s is much longer than the synchronous publish-state propagation (microseconds) used by `SessionListView` / `DetachedIslandWindowController`. The archive button is wired to actor messages, not transient phase observation. We add a regression test that creates a session, marks it ended, immediately invokes the archive action path, and verifies it succeeds even with the sweep running.

[**Risk**: Auto-approve guard mutes a session the user *wants* to be alerted about because they forgot they enabled always-allow.] → **Mitigation**: Always-allow is opt-in per session and the UI badge / hover preview / instances list still display the in-flight intervention. Only the *audible* channel is suppressed. This matches the existing `SoundManager.handleEvent` gate semantics.

[**Risk**: `kill(pid, 0)` returns success on a recycled pid (the OS reused the integer for a different process).] → **Mitigation**: macOS pid recycling is rare on the second-scale. The worst case is a stale session lingers a few extra seconds before the *next* sweep finds the recycled-pid process gone. No safety implications.

[**Risk**: `detectStatus` rewrite breaks a test that asserts the old `.completed` mapping for `Stop`.] → **Mitigation**: Tests directly exercising the mapper (`Prototype/Tests/IslandTests/HookPayloadMapperTests.swift`) need to be updated as part of this change. Listed explicitly in tasks.md.

## Migration Plan

This is a bug fix; no data migration. Rollout:
1. Land all four code changes + tests on a single branch.
2. Manual smoke: launch Claude Code, run a Bash tool, observe `taskCompleted` sound on completion. Run a Task subagent, observe parent session stays alive. Enable always-allow on a session, fire two PermissionRequests, observe zero `attentionRequired` sounds. Kill Claude with `kill -9 <pid>`, observe session disappears within 5 s.
3. Beta dogfood for 24 h with sound enabled.
4. Ship.

Rollback: revert the four diffs; behavior returns to current (broken) state, no schema or persistence to undo.

## Open Questions

- **Q1**: Should the liveness sweep also be invoked opportunistically on every hook event (so a quiet system reaps faster than the 5 s timer)? Lean **no** for now — the timer is bounded and predictable; opportunistic invocation muddies the cost model. Revisit if 5 s feels too slow in dogfood.
- **Q2**: The `default` case in the rewritten `detectStatus` switch returns `.completed` for unknown `stop`/`end` substrings. Should it instead return `.waitingForInput` (since "more inclusive Stop semantics" is the safer side of the asymmetry)? Lean **conservative `.completed`** — unknown stop-family events from a future client we haven't audited should err toward "this might mean session over" so we don't accumulate ghost sessions, and the liveness sweep is the safety net.
