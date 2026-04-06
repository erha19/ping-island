#!/usr/bin/env python3
"""
Island Claude bridge hook.

This script speaks a single bridge protocol:
- request: bridge envelope JSON over the Island Unix socket
- response: bridge response JSON from the app
"""

import json
import os
import socket
import subprocess
import sys
import time
import uuid

SOCKET_PATH = os.environ.get("ISLAND_SOCKET_PATH", "/tmp/island.sock")
TIMEOUT_SECONDS = 300
FOUNDATION_REFERENCE_UNIX = 978307200


def get_tty():
    """Get the TTY of the Claude parent process."""
    ppid = os.getppid()

    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            return tty if tty.startswith("/dev/") else f"/dev/{tty}"
    except Exception:
        pass

    for handle in (sys.stdin, sys.stdout):
        try:
            return os.ttyname(handle.fileno())
        except (OSError, AttributeError):
            continue

    return None


def get_process_name(pid):
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "comm="],
            capture_output=True,
            text=True,
            timeout=2
        )
        name = result.stdout.strip()
        return name or None
    except Exception:
        return None


def foundation_now():
    return time.time() - FOUNDATION_REFERENCE_UNIX


def compact_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def detect_ide_context(env):
    term_program = (env.get("TERM_PROGRAM") or "").lower()
    hint_values = []
    for key in (
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "VSCODE_GIT_IPC_HANDLE",
        "VSCODE_IPC_HOOK_CLI",
        "VSCODE_GIT_ASKPASS_MAIN",
        "VSCODE_CWD",
        "CURSOR_TRACE_ID",
        "CURSOR_AGENT",
        "CURSOR_GIT_ASKPASS_MAIN",
        "WINDSURF_TRACE_ID",
        "TRAE_TRACE_ID",
        "TRAE_AGENT",
        "CODEBUDDY_TRACE_ID",
        "CODEBUDDY_AGENT",
        "ZED_CHANNEL",
    ):
        value = env.get(key)
        if value:
            hint_values.append(value.lower())

    hints = " ".join(hint_values)

    if "cursor" in hints or any(key.startswith("CURSOR_") for key in env):
        return ("Cursor", "com.todesktop.230313mzl4w4u92")
    if "windsurf" in hints or any(key.startswith("WINDSURF_") for key in env):
        return ("Windsurf", "com.exafunction.windsurf")
    if "trae" in hints or any(key.startswith("TRAE_") for key in env):
        return ("Trae", "com.trae.app")
    if "codebuddy" in hints or any(key.startswith("CODEBUDDY_") for key in env):
        return ("CodeBuddy", "com.tencent.codebuddy")
    if "zed" in hints or any(key.startswith("ZED_") for key in env):
        return ("Zed", "dev.zed.Zed")
    if term_program == "vscode" or any(key.startswith("VSCODE_") for key in env):
        return ("VS Code", "com.microsoft.VSCode")

    return (None, None)


def detect_remote_context(env):
    authority = (
        env.get("VSCODE_CLI_REMOTE_AUTHORITY")
        or env.get("VSCODE_REMOTE_AUTHORITY")
        or env.get("REMOTE_CONTAINERS_IPC")
    )
    ssh_connection = env.get("SSH_CONNECTION") or env.get("SSH_CLIENT")

    if authority and "ssh-remote+" in authority:
        return ("ssh-remote", authority.split("ssh-remote+", 1)[1] or None)

    if ssh_connection:
        ssh_parts = ssh_connection.split()
        if len(ssh_parts) >= 3:
            return ("ssh", ssh_parts[2])
        return ("ssh", env.get("SSH_TTY"))

    return (None, None)


def build_terminal_context(cwd, tty):
    env = os.environ
    program = env.get("TERM_PROGRAM")
    bundle_id = env.get("__CFBundleIdentifier")
    ide_name = None
    ide_bundle_id = None

    if not bundle_id:
        if program == "iTerm.app":
            bundle_id = "com.googlecode.iterm2"
        elif program in {"Apple_Terminal", "Terminal.app"}:
            bundle_id = "com.apple.Terminal"
        else:
            ide_name, ide_bundle_id = detect_ide_context(env)
            bundle_id = ide_bundle_id
    else:
        ide_name, ide_bundle_id = detect_ide_context(env)

    transport, remote_host = detect_remote_context(env)

    return {
        "terminalProgram": program,
        "terminalBundleID": bundle_id,
        "ideName": ide_name,
        "ideBundleID": ide_bundle_id,
        "iTermSessionID": env.get("ITERM_SESSION_ID"),
        "terminalSessionID": env.get("TERM_SESSION_ID") or env.get("ITERM_SESSION_ID"),
        "tty": tty,
        "currentDirectory": cwd or env.get("PWD"),
        "transport": transport,
        "remoteHost": remote_host,
        "tmuxSession": env.get("TMUX"),
        "tmuxPane": env.get("TMUX_PANE"),
    }


def build_metadata(data, event, cwd, pid, tool_input, terminal_context):
    metadata = {
        "session_id": data.get("session_id", "unknown"),
        "hook_event_name": event,
        "cwd": cwd or "",
        "pid": str(pid),
        "client_kind": "claude_code",
        "client_name": "Claude Code",
    }

    if terminal_context.get("terminalBundleID"):
        metadata["terminal_bundle_id"] = terminal_context["terminalBundleID"]
    if terminal_context.get("terminalProgram"):
        metadata["terminal_program"] = terminal_context["terminalProgram"]
    if terminal_context.get("ideName"):
        metadata["client_originator"] = terminal_context["ideName"]
    if terminal_context.get("transport"):
        metadata["connection_transport"] = terminal_context["transport"]
    if terminal_context.get("remoteHost"):
        metadata["remote_host"] = terminal_context["remoteHost"]

    process_name = get_process_name(pid)
    if process_name:
        metadata["source_process_name"] = process_name

    for key in (
        "tool_name",
        "tool_use_id",
        "notification_type",
        "message",
        "transcript_path",
        "reason",
    ):
        value = data.get(key)
        if value is not None and value != "":
            metadata[key] = str(value)

    if tool_input:
        metadata["tool_input_json"] = compact_json(tool_input)

    return metadata


def event_status_kind(event, tool_name, tool_input, notification_type):
    if event == "UserPromptSubmit":
        return "thinking"
    if event == "PreToolUse":
        if is_ask_user_question_tool(tool_name) and tool_input.get("questions"):
            return "waitingForInput"
        return "runningTool"
    if event == "PostToolUse":
        return "active"
    if event == "PermissionRequest":
        return "waitingForApproval"
    if event == "Notification":
        if notification_type == "idle_prompt":
            return "waitingForInput"
        return "notification"
    if event in {"Stop", "SubagentStop", "SessionStart"}:
        return "waitingForInput"
    if event == "SessionEnd":
        return "completed"
    if event == "PreCompact":
        return "compacting"
    return "active"


def event_preview(event, tool_name, tool_input, message):
    if message:
        return message
    if tool_name:
        if tool_input:
            return f"{tool_name} {compact_json(tool_input)}"
        return tool_name
    return event


def event_title(event, tool_name):
    return tool_name or event


def expects_response(event, tool_name, tool_input):
    return (
        event == "PermissionRequest"
        or (event == "PreToolUse" and is_ask_user_question_tool(tool_name) and tool_input.get("questions"))
    )


def is_ask_user_question_tool(tool_name):
    if not tool_name:
        return False
    normalized = str(tool_name).strip().lower().replace("_", "")
    return normalized == "askuserquestion"


def build_envelope(data):
    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd") or os.environ.get("PWD") or ""
    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input", {}) or {}
    notification_type = data.get("notification_type")
    message = data.get("message")
    pid = os.getppid()
    tty = get_tty()
    terminal_context = build_terminal_context(cwd, tty)

    return {
        "id": str(uuid.uuid4()),
        "provider": "claude",
        "eventType": event,
        "sessionKey": f"claude:{session_id}",
        "title": event_title(event, tool_name),
        "preview": event_preview(event, tool_name, tool_input, message),
        "cwd": cwd,
        "status": {
            "kind": event_status_kind(event, tool_name, tool_input, notification_type)
        },
        "terminalContext": terminal_context,
        "expectsResponse": expects_response(event, tool_name, tool_input),
        "metadata": build_metadata(data, event, cwd, pid, tool_input, terminal_context),
        "sentAt": foundation_now(),
    }


def send_event(envelope):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(compact_json(envelope).encode())
        sock.shutdown(socket.SHUT_WR)

        if envelope.get("expectsResponse"):
            response = sock.recv(65536)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()
        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def claude_permission_output(response):
    decision = response.get("decision")
    reason = response.get("reason", "")

    if decision in {"approve", "approveForSession"}:
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }

    if decision == "deny":
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {
                    "behavior": "deny",
                    "message": reason or "Denied by user via Island",
                },
            }
        }

    return None


def claude_question_output(response):
    if response.get("decision") != "answer":
        return None

    updated_input = response.get("updatedInput")
    if not isinstance(updated_input, dict):
        return None

    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": updated_input,
        }
    }


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    event = data.get("hook_event_name", "")
    notification_type = data.get("notification_type")

    if event == "Notification" and notification_type == "permission_prompt":
        sys.exit(0)

    envelope = build_envelope(data)
    response = send_event(envelope)

    if event == "PreToolUse" and is_ask_user_question_tool(data.get("tool_name")):
        output = claude_question_output(response or {})
        if output is not None:
            print(json.dumps(output))
        sys.exit(0)

    if event == "PermissionRequest":
        output = claude_permission_output(response or {})
        if output is not None:
            print(json.dumps(output))
        sys.exit(0)


if __name__ == "__main__":
    main()
