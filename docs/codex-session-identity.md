# Codex session identity and auxiliary tasks

## Host evidence

`HookPayloadMapper` recognizes Qoder and Qoder CN hosts from explicit bundle
identifiers or IDE IPC / AskPass executable paths. Merely inheriting a variable
whose name starts with `QODER_`, `QODER_CN_`, or `QODERCN_` does not identify an
IDE, regardless of whether its value is `1`, `0`, or another value. Parent-process
context capture remains in the bridge. Standalone terminals retain priority over
unrelated IDE hints.

`HookSocketServer` combines Codex desktop source metadata with actual terminal
evidence. An IDE bundle alone cannot turn a known desktop session into a CLI
session. A TTY, terminal program, terminal session identifier, or tmux context
preserves real IDE-hosted CLI sessions. The optional `SessionClientInfo.terminalTTY`
field carries TTY evidence across snapshots and cache reloads; old JSON without
this field remains readable.

## Repairing cached routing

`SessionClientInfo.normalizedForCodexRouting` repairs a stored identity when its
own desktop evidence is sufficient. `SessionAssociationStore` applies this repair
on load and writes back changed associations. Ambiguous old records wait for new
source evidence rather than changing identity solely because they mention Qoder.

`SessionStore.normalizedCodexClientInfo` reconciles new desktop evidence with both
cached and live identities. Confirmed contaminated records receive the canonical
Codex App profile and thread link, and lose the false Qoder terminal host and
workspace URL. Real CLI terminal evidence is preserved. Session paths, remote
transport, names of user tasks, and conversation state remain available.

Ordinary `SessionClientInfo.merged` calls preserve old values when an incoming
optional field is absent. A confirmed repair uses `replacingRouting: true` so
absent routing fields explicitly clear stale values. Summary and full-snapshot
ingestion assign the reconciled result directly, avoiding a second merge that
would resurrect those values.

## Auxiliary tasks

`CodexAuxiliaryHookFilter` uses exact internal task sources and anchored dedicated
opening prompts, including title generation and ambient suggestions. These tasks
can use normal project directories and tools; neither is proof of user intent.
Conversely, JSON containing `title`, `suggestions`, `include`, or `exclude` is not
proof of an internal task. `ambient_suggestion_task` denotes a task accepted by
the user and must remain visible. Blocking questions and approvals retain their
existing protection from filtering.

## Verification

- `swift test --package-path Prototype` covers statistics flags, multiple inherited
  variables, explicit bundle / IPC hosts, and standalone terminals.
- `HookSocketServerClientInfoTests` covers desktop versus real IDE terminal input.
- `ClientProfileMatchingTests` covers cache repair, nullable routing replacement,
  legacy decoding, and CLI preservation.
- `CodexHookSessionTests` covers repair of already-live rows through hooks, thread
  summaries, and complete snapshots.
- Auxiliary filter, rollout parser, placeholder, and session-state tests cover
  helper sources and prompts alongside ordinary JSON and user-created tasks.
