# Qoder identity and question routing

Qoder products can share hook settings. An installed command's `--client-kind`
identifies its integration entry, not necessarily the process that invoked it.

| Source | Runtime profile | Display | Question / approval behavior |
| --- | --- | --- | --- |
| Qoder App (`com.qoder.app`, `Qoder.app/Contents/MacOS/Qoder`) | `qoder-app` | Qoder | Blocking transport; automatic default answers with a follow-up notice; actionable approvals |
| Qoder CN with explicit `parent_business_info.product=app` | `qoder-cn-app` | Qoder CN | Same App behavior |
| Qoder IDE (`com.qoder.ide`) | `qoder` | Qoder IDE | Existing notify-only behavior |
| Qoder CN IDE (`com.aliyun.lingma.ide`) | `qoder-cn` | Qoder CN | Existing notify-only behavior |
| `qodercli` / `qoderclicn`, including versioned executable paths | `qoder-cli` / `qoder-cn-cli` | Qoder CLI / Qoder CN CLI | Interactive CLI questions and approvals |

The currently installed Qoder CN product shares its bundle with the IDE. Do not
invent a distinct CN bundle or infer blocking App support from that bundle alone.
The `product` field may first appear at `Stop`; Qoder App must also be recognized
from its process path or bundle at the beginning of a session. Real CLI process
evidence takes precedence over inherited desktop host hints.

For CN, explicit App evidence is remembered for that exact `session_id` in
`~/.ping-island/qoder-cn-app-sessions.json`, so later hooks may omit `product`
without losing the answer channel. This ledger expires after 24 hours, retains
at most 256 sessions, and is invalidated by CLI evidence or `SessionEnd`.
Atomic writes and a file lock protect concurrent shared-hook invocations.

The bridge canonicalizes App metadata before deriving question/approval behavior.
When both desktop and CLI entries exist for the same event in the standard
settings file and its directly invoked bridge executable exists and can run,
the matching CLI entry owns delivery. If the configuration cannot be read or no
usable matching CLI entry exists, the desktop entry still delivers.
`hook_client_kind` retains the original entry identity for diagnostics.

Both shared desktop hook profiles use long `PreToolUse` / `PermissionRequest`
timeouts, so App-only installs retain the response channel. This does not turn
legacy IDE hooks into blocking approval integrations.

For App questions with options, `SessionMonitor` submits the first option for
each question using Qoder's answer keys, then retains the question notice and
the open-product action until the client continues. Questions without a complete
set of default options retain the inline answer form and do not receive invented
answers. Legacy notify-only IDE questions still show an external-client notice
when the bridge reports no response channel; they never fabricate a submission.
Normal approvals are
handled independently and never pass through QoderWork's notify-only filter.
Cached CLI labels with concrete Qoder App evidence are repaired when loaded.

Automatic panel expansion still respects the user's smart-suppression settings
in both docked and detached modes. Approval refresh detection uses the complete
request identity, including intervention-only approvals, so a new request in
the same session is not mistaken for one already shown.

Regression coverage lives in `HookPayloadMapperQoderAppTests`,
`IslandBridgeE2ETests`, `QoderAppIdentityTests`, `QoderAppHookTests`, and
`SessionManualAttentionTrackerTests`. The bridge e2e cases exercise real socket
question and approval responses for both App profiles; the shipping tests cover
decoding, cached identity repair, automatic answers, retained notices, and
attention edges. Live upstream UI behavior should be checked when changing
Qoder versions or hook protocols.
