# Codex Hook Debugging

Use [`scripts/debug-codex-hook.py`](/Users/wudanwu/Island/scripts/debug-codex-hook.py) when you need to inspect the raw payload that Codex sends to hook commands.

The script:

- reads the hook's stdin without modifying it
- records argv, cwd, a focused subset of `CODEX_*` and terminal env vars
- appends newline-delimited JSON records under `~/.ping-island-debug/codex-hooks/`

Example `~/.codex/hooks.json` snippet for temporary debugging:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/env python3 /Users/wudanwu/Island/scripts/debug-codex-hook.py"
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
            "command": "/usr/bin/env python3 /Users/wudanwu/Island/scripts/debug-codex-hook.py"
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
            "command": "/usr/bin/env python3 /Users/wudanwu/Island/scripts/debug-codex-hook.py"
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
