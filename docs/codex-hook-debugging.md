# Codex Hook Debugging

Use `scripts/debug-codex-hook.py` when you need to inspect the raw payload that Codex sends to hook commands.

The script:

- reads the hook's stdin without modifying it
- records argv, cwd, a focused subset of `CODEX_*` and terminal env vars
- appends newline-delimited JSON records under `~/.ping-island-debug/codex-hooks/`
- forwards the same payload to `~/.ping-island/bin/ping-island-bridge --source codex` when that bridge launcher is available

Use `PING_ISLAND_DEBUG_LOG_ONLY=1` or `--log-only` when you explicitly want capture-only mode with no bridge forwarding.

Example `~/.codex/hooks.json` snippet for temporary debugging:

```bash
REPO_ROOT="/absolute/path/to/ping-island"
```

Replace `"$REPO_ROOT"` in the JSON snippet below with the real absolute repo path before saving it into `~/.codex/hooks.json`.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/env python3 \"$REPO_ROOT/scripts/debug-codex-hook.py\""
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/env python3 \"$REPO_ROOT/scripts/debug-codex-hook.py\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/env python3 \"$REPO_ROOT/scripts/debug-codex-hook.py\""
          }
        ]
      }
    ]
  }
}
```

Inspect the latest records with:

```bash
tail -n 20 ~/.ping-island-debug/codex-hooks/$(date +%Y%m%d).jsonl
```

If you want to see only captured payloads without forwarding into Ping Island, run the same command with `--log-only`:

```json
{
  "type": "command",
  "command": "/usr/bin/env python3 \"$REPO_ROOT/scripts/debug-codex-hook.py\" --log-only"
}
```
