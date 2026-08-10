#!/usr/bin/env python3
"""Shared hook-registration logic for ~/.claude/settings.json.

Used by install.sh (initial registration), skill-updater.sh (daily
self-heal, in case a hook entry silently disappears -- a documented
incident in a sibling project), and install.sh --doctor (check-only health
report). One definition of "which hooks are expected" instead of three
copies of the list that could drift out of sync with each other.

Usage:
  thememate-hooks.py sync    # register any missing expected hook, safely
  thememate-hooks.py check   # report status only, never writes

Safe-write pattern: refuse to touch a settings.json that doesn't parse
(print the hook commands for manual addition instead of guessing); back up
the existing file before writing; write the merged result to a temp file in
the same directory and re-parse THAT file to confirm it's valid JSON before
atomically replacing the original. Earlier versions of this repo's
install.sh / skill-updater.sh wrote settings.json directly with none of
this -- a corrupt or partial write there can break Claude Code entirely.
"""
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

SETTINGS_PATH = Path.home() / ".claude" / "settings.json"
TELEMETRY_OPTOUT_MARKER = Path.home() / ".claude" / ".thememate-telemetry-optout"


def wanted_hooks():
    hooks = [("UserPromptSubmit", "bash $HOME/.claude/skill-updater.sh")]
    if not TELEMETRY_OPTOUT_MARKER.exists():
        hooks += [
            ("Stop", "python3 $HOME/.claude/thememate-autolog.py"),
            ("SessionEnd", "python3 $HOME/.claude/thememate-autolog.py"),
        ]
    return hooks


def _is_wired(settings, event, command):
    blocks = (settings.get("hooks") or {}).get(event, [])
    return any(
        any(h.get("command") == command for h in b.get("hooks", []))
        for b in blocks
        if isinstance(b, dict)
    )


def load_settings():
    """Returns (settings_dict, error_message_or_None). Never raises."""
    if not SETTINGS_PATH.is_file():
        return {}, None
    try:
        return json.loads(SETTINGS_PATH.read_text()), None
    except Exception as e:
        return None, str(e)


def check():
    """Check-only: report status, change nothing. Returns True iff every
    expected hook is registered."""
    settings, err = load_settings()
    if err is not None:
        print(f"  FAIL  settings.json is not valid JSON ({err})")
        return False
    all_ok = True
    for event, command in wanted_hooks():
        if _is_wired(settings, event, command):
            print(f"  ok    {event} hook registered")
        else:
            print(f"  FAIL  {event} hook NOT registered")
            all_ok = False
    return all_ok


def sync():
    """Register any missing expected hook. Returns True on success
    (including "nothing to do"), False if it refused to touch an
    unparseable file or the write itself failed."""
    settings, err = load_settings()
    if err is not None:
        print(f"  settings.json is not valid JSON ({err}); refusing to edit it")
        print('  add these hooks by hand under settings.json\'s "hooks" key:')
        for event, command in wanted_hooks():
            print(f"    {event}: {command}")
        return False

    changed = False
    for event, command in wanted_hooks():
        if _is_wired(settings, event, command):
            print(f"  {event} hook already present -- skipped")
            continue
        hooks = settings.setdefault("hooks", {})
        blocks = hooks.setdefault(event, [])
        blocks.append({"matcher": "", "hooks": [{"type": "command", "command": command}]})
        changed = True
        print(f"  {event} hook added")

    if not changed:
        return True

    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    if SETTINGS_PATH.is_file():
        try:
            shutil.copy2(SETTINGS_PATH, str(SETTINGS_PATH) + ".bak-thememate")
        except Exception:
            pass  # best-effort backup -- don't let a backup failure block the real write

    fd, tmp_path = tempfile.mkstemp(dir=str(SETTINGS_PATH.parent), prefix=".settings.", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(settings, f, indent=2)
        # Prove the file we're about to install actually parses before trusting it.
        with open(tmp_path) as f:
            json.load(f)
        os.replace(tmp_path, SETTINGS_PATH)
        return True
    except Exception as e:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass
        print(f"  could not update settings.json: {e}")
        return False


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "sync"
    if action == "check":
        ok = check()
    elif action == "sync":
        ok = sync()
    else:
        print(f"unknown action: {action}", file=sys.stderr)
        sys.exit(2)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
