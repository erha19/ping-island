# Session-aware keep-awake

The General settings page controls one persisted `keepAwakeMode` for both docked and detached presentation. The cup shortcut beside temporary mute turns automatic protection on or turns any enabled mode off. Select **Always on** in General settings when manual protection is wanted. Hover the header buttons for localized help: Settings indicates available updates, Mute explains the ten-minute action or restoration deadline, and Keep-awake explains working/grace/low-battery/always status. Tooltips follow the app language (English or Simplified Chinese).

- **Off** (default): no power assertion.
- **Auto**: hold while any tracked session is processing or compacting. When the last working session stops, hold for another 120 seconds. Repeated idle events do not extend the deadline. Waiting for input/approval is not active work.
- **Always on**: hold regardless of sessions or battery percentage, until disabled or the app exits. This preference survives app restarts.

Only system idle sleep is prevented (`kIOPMAssertPreventUserIdleSystemSleep`). Display sleep is unaffected. Lid-close sleep and explicit system sleep are not prevented.

Auto pauses at or below 35% on battery. While work or a grace window exists, the controller checks power every 30 seconds, including while paused. Plugging in or recovering charge restores protection on the next check without needing another session event. Unknown charge does not block protection. A successfully held Always-on assertion needs no repeating timer.

`KeepAwakePolicy` owns the pure decision and its reason. `SessionKeepAwakeController` owns session aggregation, the transition timestamp, timers, and the sole `IOPMSystemSleepAssertionClient`. The UI distinguishes intended policy from actual assertion ownership. App startup/termination explicitly starts/stops the controller; OS process teardown also releases assertions.

The implementation combines PR #307's UI, lifecycle, injected dependencies, and internal-battery reader with PR #309's three-state policy and reasons. The old experimental `preventSleepWhileWorkingEnabled` boolean migrates to Auto/Off only when no newer mode exists, then is removed. Do not start a second controller for one of the original PRs.

## Verification

`KeepAwakePolicyTests`, `SessionKeepAwakeTests`, and `KeepAwakeSettingsTests` cover decisions, controller transitions and power recovery, assertion state, and preference migration. Run the root Xcode unit tests to include these shipping-app files.

On a Mac without other processes holding a competing assertion:

1. Select Auto and start a working session. `pmset -g assertions` should show `Ping Island: keep awake` under `PreventUserIdleSystemSleep`.
2. Let all work stop. The assertion should release after 120 seconds; repeated idle events must not prolong it.
3. Disable the feature and confirm prompt release. Select Always on and confirm protection without sessions; select Off afterward.
4. Verify low-battery pause and AC restoration within a 30-second polling interval during a quiet long-running tool.
5. Confirm normal display sleep and that idle system sleep resumes after release.

A successful IOKit call or CI build alone does not verify actual hardware idle sleep. Avoid SSH/Screen Sharing assertions confounding that manual check.
