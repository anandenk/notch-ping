#!/usr/bin/env python3
"""Add/remove only Notch Ping observer hooks; retain unrelated configuration."""
import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import shlex
import stat
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def command(helper, provider):
    return shlex.quote(str(helper)) + " hook " + provider


def entries(provider):
    if provider == "agy":
        question_tools = "ask_question|ask_user_question|request_user_input"
        return [("Stop", None), ("PreInvocation", None), ("SessionStart", None),
                ("SessionEnd", None), ("PreToolUse", question_tools), ("PostToolUse", question_tools)]
    common = [("SessionStart", None), ("UserPromptSubmit", None), ("Stop", None),
              ("PermissionRequest", None), ("PostToolUse", None), ("SessionEnd", None)]
    if provider == "codex":
        return common + [("Interrupt", None), ("PreToolUse", "request_user_input")]
    return common + [("PreToolUse", "AskUserQuestion|ExitPlanMode"),
                     ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"),
                     ("Elicitation", None), ("ElicitationResult", None), ("StopFailure", None)]


def amend_agy(original, helper, install):
    result = copy.deepcopy(original)
    if not isinstance(result, dict):
        raise ValueError("Existing hooks value is not an object")
    base = command(helper, "agy")
    known_agy_events = {event for event, _ in entries("agy")} | {
        "Stop", "PreInvocation", "PostInvocation", "SessionStart", "SessionEnd", "PreToolUse", "PostToolUse"
    }
    owned_commands = {base} | {base + " " + event for event in known_agy_events}

    removed = object()

    def keep_handler(handler):
        if not isinstance(handler, dict):
            return handler
        if handler.get("type", "command") == "command" and handler.get("command") in owned_commands:
            return removed
        if isinstance(handler.get("hooks"), list):
            kept = [item for item in (keep_handler(item) for item in handler["hooks"]) if item is not removed]
            if len(kept) != len(handler["hooks"]):
                if not kept:
                    return removed
                handler["hooks"] = kept
        return handler

    # Match only complete commands emitted by our installer. A mention, shell
    # wrapper, extra argument, or similar prefix is not proof of ownership.
    for hook_name, events in list(result.items()):
        if not isinstance(events, dict):
            continue
        for event_name, handlers in list(events.items()):
            if not isinstance(handlers, list):
                continue
            kept = [item for item in (keep_handler(item) for item in handlers) if item is not removed]
            if len(kept) != len(handlers):
                if kept:
                    events[event_name] = kept
                else:
                    events.pop(event_name)
        if not events and original[hook_name]:
            result.pop(hook_name)

    if install:
        notch_hook = result.setdefault("notch-ping", {})
        if not isinstance(notch_hook, dict):
            raise ValueError("Existing notch-ping hook value is not an object")
        for event, matcher in entries("agy"):
            handler = {"type": "command", "command": base + " " + event, "timeout": 1}
            group = {"matcher": matcher, "hooks": [handler]} if matcher else handler
            handlers = notch_hook.setdefault(event, [])
            if not isinstance(handlers, list):
                raise ValueError("Existing notch-ping hook event is not an array: " + event)
            handlers.append(group)
    return result


def amend(original, provider, helper, install):
    if provider == "agy":
        return amend_agy(original, helper, install)
    result = copy.deepcopy(original)
    hooks = result.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Existing hooks value is not an object")
    owned_command = command(helper, provider)
    # Exact command match only. Never remove other providers' or users' handlers.
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            raise ValueError("Existing hook event is not an array: " + event)
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("Invalid hook group: " + event)
            group = copy.deepcopy(group)
            group["hooks"] = [h for h in group["hooks"]
                              if not (h.get("type") == "command" and h.get("command") == owned_command)]
            if group["hooks"]:
                kept.append(group)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
    if install:
        for event, matcher in entries(provider):
            group = {"hooks": [{"type": "command", "command": owned_command,
                                "async": True, "timeout": 1}]}
            if matcher:
                group["matcher"] = matcher
            hooks.setdefault(event, []).append(group)
    if not hooks:
        result.pop("hooks", None)
    return result


def ensure_private_dir(path, mode=0o700):
    if path.is_symlink():
        raise ValueError("Refusing to traverse symlink directory: " + str(path))
    path.mkdir(parents=True, exist_ok=True, mode=mode)
    if path.is_symlink():
        raise ValueError("Refusing to use symlink directory: " + str(path))
    os.chmod(path, mode)


def atomic_write(target, data, mode):
    if target.is_symlink() or target.parent.is_symlink():
        raise ValueError("Refusing to write through symlink: " + str(target))
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".notch-ping-", dir=target.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as file:
            file.write(data)
        if target.is_symlink():
            raise ValueError("Refusing to replace symlink: " + str(target))
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def update(home, install, relay):
    support = home / "Library/Application Support/NotchPing"
    helper = support / "bin/notch-relay"
    targets = {
        "codex": home / ".codex/hooks.json",
        "claude": home / ".claude/settings.json",
        "agy": home / ".gemini/config/hooks.json",
    }
    plans = []
    for provider, target in targets.items():
        if target.is_symlink() or target.parent.is_symlink():
            raise ValueError("Refusing to replace symlink: " + str(target))
        before = target.read_bytes() if target.exists() else None
        original = json.loads(before) if before else {}
        if not isinstance(original, dict):
            raise ValueError("Settings root is not an object: " + str(target))
        changed = amend(original, provider, helper, install)
        if changed == original:
            continue
        after = (json.dumps(changed, indent=2, ensure_ascii=False) + "\n").encode()
        mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
        plans.append((target, before, after, mode))

    if install:
        if not relay.is_file() or relay.is_symlink():
            raise ValueError("Build the app first; relay not found: " + str(relay))
        ensure_private_dir(support, 0o700)
        ensure_private_dir(helper.parent, 0o700)
        # Replacing the executable atomically leaves an already-running hook intact.
        atomic_write(helper, relay.read_bytes(), 0o700)

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backups_root = support / "backups"
    backup = backups_root / stamp
    completed = []
    try:
        for target, before, after, mode in plans:
            current = target.read_bytes() if target.exists() else None
            if current != before:
                raise RuntimeError("Settings changed concurrently: " + str(target))
            ensure_private_dir(support, 0o700)
            ensure_private_dir(backups_root, 0o700)
            ensure_private_dir(backup, 0o700)
            if target == targets["codex"]:
                name = "codex-hooks.json"
            elif target == targets["claude"]:
                name = "claude-settings.json"
            else:
                name = "gemini-hooks.json"
            if before is not None:
                atomic_write(backup / name, before, 0o600)
            else:
                atomic_write(backup / (name + ".absent"), b"File did not exist before installation.\n", 0o600)
            atomic_write(target, after, mode)
            completed.append((target, before, after, mode))
            print(("Installed: " if install else "Removed hooks: ") + str(target))
    except Exception:
        for target, before, after, mode in reversed(completed):
            if target.read_bytes() == after:
                if before is None:
                    target.unlink()
                else:
                    atomic_write(target, before, mode)
        raise
    if plans:
        print("Backups: " + str(backup))
    else:
        print("Hook configuration already up to date.")
    if not install and helper.exists():
        helper.unlink()
    return helper


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("--home", type=Path, default=Path.home(), help="Settings home; override only for fixture testing")
    parser.add_argument("--relay", type=Path, default=ROOT / "dist/Notch Ping.app/Contents/MacOS/notch-relay")
    args = parser.parse_args()
    try:
        update(args.home, args.action == "install", args.relay)
    except Exception as error:
        parser.exit(1, "No further settings changed: " + str(error) + "\n")
