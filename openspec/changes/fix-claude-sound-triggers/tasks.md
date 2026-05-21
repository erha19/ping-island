## 1. Pre-flight audit (no code changes)

- [x] 1.1 Confirmed: `ClientProfile.swift` lines 526-529 / 576-577 / 633-634 etc register `SessionEnd` independently for each client family; `Stop` and `SessionEnd` are separate descriptors. Hermes uses Stop only as a file-sync trigger (`SessionEvent.swift:665`).
- [x] 1.2 Confirmed: `grep` shows `clientKind == "kimi"` exists only at `HookPayloadMapper.swift:404`.
- [x] 1.3 Audit complete. SessionStore consumers of Stop/ended:
    - L420 `if !(status==ended && phase==.ended)` skip lastActivity — under new mapping only triggers on duplicate SessionEnd; more correct, no break.
    - L441-449 `shouldPreserveEndedStopForAnsweredQuestion` + `markSessionEnded` — under new mapping `status=="ended" && event=="Stop"` is impossible, so this becomes dead code (not a bug, leave it; could clean up in a follow-up).
    - L592 `if event.event == "Stop" { subagentState = SubagentState() }` — keyed on event name, not status; matches vibe-notch's own Stop cleanup.
    - L808 `processKimiHookCompletion` — keyed on event name, unaffected.
    - L2017 / L2446 / L2523 / L4071 — all branch on `event.event` names; status mapping change does not affect them.
    - **No consumer breaks.** No tests in §1.3 need rewriting purely from this audit.

## 2. Bug 1: Stop / SubagentStop / StopFailure mapping

- [x] 2.1 In `Prototype/Sources/IslandShared/HookPayloadMapper.swift:400-408`, replace the `if lowered.contains("stop") || lowered.contains("end")` block with the name-keyed switch from `design.md` §Decision 1. Drop the `clientKind == "kimi"` special case.
- [x] 2.2 Update or add tests in `Prototype/Tests/IslandTests/HookPayloadMapperTests.swift` for: Claude `Stop` → `.waitingForInput`; Claude `SubagentStop` → `.runningTool`; Claude `StopFailure` → `.waitingForInput`; Claude `SessionEnd` → `.completed`; Kimi `Stop` (regression — same as Claude now); unknown `stop`/`end` substring → `.completed` (default-case safety).
- [x] 2.3 Add a `PingIslandTests/SessionStoreCodexInterventionTests.swift`-style integration test (new file or extension): synthesize a Claude `Stop` `HookEvent`, push through `SessionStore.processHookEvent`, assert resulting `SessionState.phase == .waitingForInput` and `markSessionEnded` was NOT called (e.g. `autoApprovePermissions` preserved).
- [x] 2.4 Add an integration test for Claude `SubagentStop`: parent session with `autoApprovePermissions = true` and an active `Task` tool, push `SubagentStop`, assert phase stays in a "still working" state and `markSessionEnded` was NOT called.
- [x] 2.5 Re-run the tests touched in 1.3 if any branched on `event.event == "Stop"`-implies-end and update them to reflect the new semantics.

## 3. Bug 2: auto-approve must not ring `attentionRequired`

- [x] 3.1 In `PingIsland/UI/Views/NotchView.swift:1267-1269`, change the `attentionSessions` filter to the form in `design.md` §Decision 2 (`guard !session.autoApprovePermissions else { return false }` then existing predicate).
- [x] 3.2 Apply the identical change at `PingIsland/UI/Window/DetachedIslandWindowController.swift:1680-1682`.
- [x] 3.3 Add a `PingIslandTests/` test that drives the edge detector with a pre-armed session whose `autoApprovePermissions == true`, plus two consecutive `PermissionRequest`-induced state transitions. Assert `playEventSoundIfNeeded(.attentionRequired, ...)` is NOT invoked. Either spy on `AppSettings.playSound(...)` or extract the filter into a small helper that's directly testable.
- [x] 3.4 Add a regression test for the toggle-off path: arm `autoApprovePermissions = true`, fire one `PermissionRequest`, assert silence; then set `autoApprovePermissions = false`, fire another, assert the attention sound IS eligible (the filter no longer excludes it).

## 4. Bug 3 / Vibe-notch borrow: process-liveness sweep

- [x] 4.1 In `PingIsland/Services/State/SessionStore.swift`, add the actor-internal `livenessTask`, `startLivenessSweep()`, `stopLivenessSweep()`, and `sweepDeadOrEndedSessions()` per `design.md` §Decision 3. Use `kill(Int32(pid), 0) == 0` for the liveness check; sessions with no `pid` are left alone.
- [x] 4.2 Wire `startLivenessSweep()` into `SessionMonitor.startMonitoring()` and `stopLivenessSweep()` into `SessionMonitor.stopMonitoring()`. Mirror the existing pattern used by other periodic tasks in `SessionMonitor` (e.g., `maintenanceTask`).
- [x] 4.3 Verify `cancelPendingSync(sessionId:)` (or whichever per-session task cancellers exist) is invoked from `sweepDeadOrEndedSessions` for every removed session — grep `pending*` collections in `SessionStore` and ensure each is covered.
- [x] 4.4 Add a unit test in `PingIslandTests/` that primes `SessionStore` with a session whose `pid` is a guaranteed-dead value (e.g., `Int.max` or a forked-and-waited child), invokes `sweepDeadOrEndedSessions` directly, asserts the session is removed and `publishState` was called.
- [x] 4.5 Add a unit test that primes a session with `phase = .ended` (set via `markSessionEnded`), invokes the sweep, asserts removal.
- [x] 4.6 Add a unit test that primes a session with no `pid`, invokes the sweep, asserts the session is NOT removed (negative test for the "unknown pid → keep" rule).
- [x] 4.7 Add a unit test that primes a session whose `pid` belongs to the current process (`getpid()`, guaranteed alive), `phase != .ended`, invokes the sweep, asserts no removal and no `publishState` if no other change occurred.

## 5. Cross-cutting verification

- [x] 5.1 Full Prototype test suite (104 tests) green. Full PingIslandTests target green. PingIslandUITests crashes due to no-signing infra (pre-existing, unrelated). Two pre-existing tests in `HookPayloadMapperTests.swift` (`qwenCodeStopUsesLastAssistantMessageAsPreview`, `hermesStopUsesLastAssistantMessageAsPreview`) asserted the old `.completed` mapping for Claude `Stop`; updated to expect `.waitingForInput` per the new spec.
- [ ] 5.2 Manual smoke per `design.md` §Migration Plan: (a) Claude finishes a Bash tool → `taskCompleted` sound fires once; (b) Claude `Task` subagent completes → parent session stays alive in the list; (c) enable always-allow on a session, fire two `PermissionRequest`-triggering tool calls, confirm zero `attentionRequired` sounds; (d) `kill -9` the Claude process, confirm session disappears from the UI within ~5 s. **Needs human verification** — code & unit tests are ready for dogfood.
- [x] 5.3 Verified by inspection: no UI component under `PingIsland/UI/` reads `session.autoApprovePermissions` to gate badge / hover preview / list rendering. `SessionHoverPreviewView`, `SessionConversationPreviewBuilder`, `SessionManualAttentionTracker` all read `needsApprovalResponse` only — so always-allow sessions still flicker the badge during the in-flight window, only audio is suppressed via the new evaluator.
- [x] 5.4 Verified by inspection: `sessionArchived` is processed via the same `SessionStore` actor as `sweepDeadOrEndedSessions`. Actor reentrancy serializes them — they cannot interleave. Either order is correct (sweep finds session and removes it, then archive becomes a no-op; or archive runs first and sweep finds nothing).

## 6. Documentation and rollout

- [ ] 6.1 Update the PR description with the multi-client audit summary from §1.1. **Pending PR creation.**
- [x] 6.2 Added bilingual fix entries to `releases/notes/0.14.0.md` covering the four user-visible fixes.
- [ ] 6.3 After merge, run `openspec archive fix-claude-sound-triggers` to fold the spec into `openspec/specs/session-notification-correctness/spec.md`. **Post-merge step.**
