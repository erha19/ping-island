#!/usr/bin/env python3
"""
Minimal Codex hook debugger.

This script captures the raw stdin payload, argv, and a focused subset of
environment variables so we can inspect what Codex hooks actually provide.
When PingIslandBridge is available, it also forwards the hook payload so the
normal Ping Island session flow keeps working during debugging.

It is intentionally side-effect light:
- writes newline-delimited JSON records to disk
- forwards stdout/stderr from PingIslandBridge when forwarding is enabled
- exits 0 unless logging or bridge forwarding crashes
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_LOG_DIR = Path.home() / ".ping-island-debug" / "codex-hooks"
DEFAULT_BRIDGE_PATH = Path.home() / ".ping-island" / "bin" / "ping-island-bridge"
INTERESTING_ENV_KEYS = [
    "CODEX_THREAD_ID",
    "PWD",
    "TERM",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "TERM_SESSION_ID",
    "ITERM_SESSION_ID",
    "TMUX",
    "TMUX_PANE",
    "TTY",
    "__CFBundleIdentifier",
]


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def detect_event(argv: list[str], parsed_payload: object | None) -> str | None:
    if isinstance(parsed_payload, dict):
        for key in ("hook_event_name", "event", "type"):
            value = parsed_payload.get(key)
            if isinstance(value, str) and value.strip():
                return value

    if "--event" in argv:
        index = argv.index("--event")
        if index + 1 < len(argv):
            return argv[index + 1]

    return None


def collect_environment() -> dict[str, str]:
    return {
        key: value
        for key, value in os.environ.items()
        if key in INTERESTING_ENV_KEYS or key.startswith("CODEX_")
    }


def parse_json(raw_text: str) -> object | None:
    stripped = raw_text.strip()
    if not stripped:
        return None

    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        return None


def should_forward(argv: list[str]) -> bool:
    if "--log-only" in argv:
        return False

    log_only = os.environ.get("PING_ISLAND_DEBUG_LOG_ONLY", "").strip().lower()
    return log_only not in {"1", "true", "yes"}


def resolve_bridge_command() -> list[str] | None:
    override = os.environ.get("PING_ISLAND_CODEX_BRIDGE", "").strip()
    candidates = []
    if override:
        candidates.append(Path(override).expanduser())
    candidates.append(DEFAULT_BRIDGE_PATH)

    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return [str(candidate), "--source", "codex"]

    return None


def forward_to_bridge(raw_stdin: str) -> tuple[bool, list[str] | None, int, str, str]:
    command = resolve_bridge_command()
    if command is None:
        return False, None, 0, "", ""

    completed = subprocess.run(
        command,
        input=raw_stdin,
        capture_output=True,
        text=True,
        env=os.environ.copy(),
        check=False,
    )
    return True, command, completed.returncode, completed.stdout, completed.stderr


def main() -> int:
    raw_stdin = sys.stdin.read()
    parsed_payload = parse_json(raw_stdin)
    event = detect_event(sys.argv[1:], parsed_payload) or "unknown"
    should_forward_to_bridge = should_forward(sys.argv[1:])
    forwarded = False
    bridge_command: list[str] | None = None
    bridge_exit_code = 0
    bridge_stdout = ""
    bridge_stderr = ""

    if should_forward_to_bridge:
        forwarded, bridge_command, bridge_exit_code, bridge_stdout, bridge_stderr = forward_to_bridge(raw_stdin)

    log_dir = Path(
        os.environ.get("PING_ISLAND_CODEX_HOOK_DEBUG_DIR", DEFAULT_LOG_DIR)
    ).expanduser()
    log_dir.mkdir(parents=True, exist_ok=True)

    record = {
        "id": str(uuid.uuid4()),
        "timestamp": utc_timestamp(),
        "event": event,
        "argv": sys.argv[1:],
        "cwd": os.getcwd(),
        "forwarding_enabled": should_forward_to_bridge,
        "forwarded_to_bridge": forwarded,
        "bridge_command": bridge_command,
        "bridge_exit_code": bridge_exit_code if forwarded else None,
        "environment": collect_environment(),
        "stdin_raw": raw_stdin,
        "stdin_json": parsed_payload,
    }

    log_path = log_dir / f"{datetime.now(timezone.utc).strftime('%Y%m%d')}.jsonl"
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True))
        handle.write("\n")

    if bridge_stdout:
        sys.stdout.write(bridge_stdout)
    if bridge_stderr:
        sys.stderr.write(bridge_stderr)

    return bridge_exit_code if forwarded else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        sys.stderr.write(f"debug-codex-hook failed: {exc}\n")
        raise SystemExit(1)
