#!/usr/bin/env python3
"""Stop/SessionEnd hook: deterministic backstop for ThemeMate session_start/
session_end telemetry, which SKILL.md's own instructions cannot guarantee on
their own -- the LLM must remember to run them mid-task, with no external
check that it actually did.

WHY THIS EXISTS
    Three prior fixes (commits 8ec3558, 166abd4, ef5293b) added more prose /
    TodoWrite reminders to SKILL.md's telemetry section. A live session still
    emitted zero telemetry for six user turns despite the latest reminder --
    nothing outside the LLM's own narration ever verified these calls fired.

HOOK CHOICE (validated empirically, not assumed from docs)
    `InstructionsLoaded` was the original plan for detecting "this session
    touched ThemeMate," but it never fired in three separate live test
    sessions despite the skill demonstrably loading (confirmed via its full
    body appearing in the transcript). It is not used here. Detection instead
    rides on `Stop`, which DID fire reliably in testing: the first `Stop` call
    for a given Claude session does a one-time scan for the skill's marker
    path and records the verdict, so later `Stop` calls for the same session
    just stat+read a tiny state file instead of re-scanning.

    `SessionEnd` fired on a graceful exit and on a SIGTERM-based kill, but did
    NOT fire when the process was sent SIGKILL -- confirmed by testing, not
    assumed. That means this script is NOT a complete backstop by itself: a
    hard-killed session (crashed machine, `kill -9`) leaves no client-side
    hook to run at all. The Apps Script side (telemetry/apps-script/Code.gs's
    `reconcileStaleSessions_`) closes that remaining gap with a periodic
    sweep for stale open sessions -- this script only handles what a live
    process can still observe about itself.

HOW IT AVOIDS FALSE POSITIVES
    The "did session_start/session_end actually fire" scan is restricted to
    `Bash` tool_use `input.command` text, never transcript text generally.
    SKILL.md's own Section 14 contains the literal string
    "telemetry-emit.sh session_start" in its documentation/examples, which
    enters the transcript as soon as the skill loads -- a whole-text match
    would see "already fired" before anything actually ran. The one-time
    "is this a ThemeMate session at all" check is deliberately a separate,
    broader text search (it only needs to prove the skill loaded, not that a
    specific command ran, so the false-positive concern above doesn't apply
    to it).

WHY IDENTITY RESOLUTION USES THE LOCAL TELEMETRY LOG, NOT THE TRANSCRIPT
    Confirmed live: the LLM does not always pass a literal UUID after
    `session_id=` -- one real session generated the UUID once into a shell
    variable (`SESSION_ID=$(...)`, even round-tripped through a temp file)
    and referenced `session_id=$SESSION_ID` in both calls. That's *better*
    session_id continuity than a literal, re-typed value would give, but no
    static text scan of the transcript's (pre-execution) command string can
    ever recover the resolved value -- this script never executes shell.

    telemetry-emit.sh's own local audit log (~/.claude/.thememate-telemetry.log)
    solves this for free: it logs bash's ALREADY-RESOLVED positional argv at
    actual execution time, so the log always holds the real literal
    session_id regardless of how the LLM constructed it. So: "did
    session_start/session_end happen at all" is still tracked from the
    transcript (presence-only, no capture group -- it's the only signal
    that's inherently scoped to *this* Claude session, since the log is a
    shared/global file with no per-terminal correlation of its own), but
    "which literal session_id to close" is resolved by correlating this
    session's own session_start Bash-call transcript timestamp against the
    log's timestamp, within a tight window (CORRELATION_WINDOW_SECONDS). A
    global sweep of the shared log by time-since-last-line alone was
    considered and rejected: session_heartbeat's cadence is turn-count-based
    ("every 5 user turns"), not wall-clock-based, so a real in-progress
    session in another terminal can easily go quiet longer than any short
    buffer -- a loose global sweep would wrongly close live sessions. A tight
    per-session timestamp correlation has the opposite, safe failure
    direction: too-tight a match just means "fall through to the slower
    reconcileStaleSessions_ sweep," never "wrongly close a session that's
    still running."

PERFORMANCE
    Each in-scope session gets one small JSON state file storing a byte
    offset into its own transcript. Every `Stop` call reads only bytes
    appended since the last call -- cost is independent of total transcript
    size and of how many turns have elapsed since `session_start` last fired.
    Out-of-scope sessions (the large majority of Claude Code sessions, which
    never touch this skill) cost one stat + a few-byte read per turn after
    the first.

CONTRACT
    Never blocks, never raises, always exits 0. Never fires a backstop for an
    event the LLM's own emission has already covered. State reads use
    `.get()` with defaults throughout so a state file written by a prior
    version of this script (e.g. mid-session across a redeploy) degrades to
    sensible defaults instead of erroring.
"""
import json
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path

STATE_DIR = Path.home() / ".claude" / ".thememate-active"
TELEMETRY_SCRIPT = Path.home() / ".claude" / "telemetry-emit.sh"
LOG_FILE = Path.home() / ".claude" / ".thememate-telemetry.log"

# Confirmed against a real transcript, not assumed: Claude Code injects
# "Base directory for this skill: /Users/.../.claude/skills/swym-thememate"
# (absolute path, no "/SKILL.md" suffix) -- NOT "swym-thememate/SKILL.md" as
# originally assumed here, which never matched a single real session and
# silently marked every one of them out of scope. "skills/swym-thememate" is
# specific enough to not fire on an incidental mention of the skill's name in
# conversation, while being robust to the machine-specific home dir prefix.
SKILL_MARKER = "skills/swym-thememate"

# Turn-count floor absorbs "still resolving MODE on turn 1"; wall-clock floor
# absorbs "burned through 3 cached-role turns in a few seconds." Both must
# hold before concluding session_start was actually skipped rather than just
# not-yet-reached (BRAND_DISCOVER's Playwright cold start alone can exceed
# 90s within turn 1).
GRACE_MIN_STOPS = 3
GRACE_MIN_SECONDS = 90

# How close a transcript Bash-call timestamp and a local-log line timestamp
# must be to treat them as the same event. The log write happens synchronously
# in the same shell invocation that produced the matching transcript entry,
# so this only needs to cover normal tool-dispatch/shell-exec latency, not
# anything session-lifetime-scale -- see module docstring.
CORRELATION_WINDOW_SECONDS = 45

# Word-boundary, presence-only (no capture group) so this can't match inside
# a longer identifier and doesn't need to resolve any value -- restricted to
# text already scoped to Bash tool_use `input.command` by the caller.
SESSION_START_PRESENT_RE = re.compile(r"telemetry-emit\.sh\s+session_start\b")
SESSION_END_PRESENT_RE = re.compile(r"telemetry-emit\.sh\s+session_end\b")

# Matches telemetry-emit.sh's own local audit-log line format exactly:
# "<ts> event=<event> session_id=<id-or-empty>".
LOG_LINE_RE = re.compile(r"^(?P<ts>\S+)\s+event=(?P<event>\S+)\s+session_id=(?P<sid>[0-9A-Fa-f-]*)\s*$")


def read_hook_input():
    try:
        import select

        if sys.stdin is None or sys.stdin.closed:
            return {}
        ready, _, _ = select.select([sys.stdin], [], [], 1.0)
        return json.loads(sys.stdin.read() or "{}") if ready else {}
    except Exception:
        return {}


def state_path(claude_session_id):
    # claude_session_id is a hook-provided UUID, but never trust a stdin
    # field as a bare path component.
    safe = re.sub(r"[^A-Za-z0-9-]", "", claude_session_id or "")
    if not safe:
        return None
    return STATE_DIR / f"{safe}.json"


def load_state(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def save_state(path, state):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(state))
        tmp.chmod(0o600)
        tmp.replace(path)
    except Exception:
        pass


def fresh_state():
    return {
        "is_thememate": True,
        "offset": 0,
        "saw_session_start": False,
        "session_start_ts": None,  # transcript (or hook-generated) timestamp
                                    # of the moment session_start happened --
                                    # kept only for the one-time log
                                    # correlation at SessionEnd.
        "saw_session_end": False,
        "stop_count": 0,
        "marker_ts": time.time(),
        "done": False,
    }


def looks_like_thememate_session(transcript_path):
    """One-time, whole-transcript-so-far check -- cheap because this only
    ever runs on a session's first Stop, when the transcript holds at most
    one turn's content."""
    try:
        with open(transcript_path, "r", errors="ignore") as f:
            return SKILL_MARKER in f.read(50_000_000)
    except Exception:
        return False


def scan_new_bash_events(transcript_path, offset):
    """Return (list of (command, timestamp) pairs, new_offset). Reads only
    bytes appended since `offset`; resets to 0 and rescans if `offset` no
    longer fits the file (e.g. a mid-session /compact rewrote it) -- safe
    since callers only use this to flip booleans and capture a first-seen
    timestamp, not to accumulate order-dependent state.

    `timestamp` is the enclosing assistant JSONL line's own top-level
    `timestamp` field (confirmed present on every real assistant line,
    ISO-8601 with milliseconds) -- used only to correlate against the local
    telemetry log at SessionEnd, never persisted beyond that one lookup."""
    try:
        size = Path(transcript_path).stat().st_size
    except Exception:
        return [], offset
    if offset > size:
        offset = 0
    try:
        with open(transcript_path, "rb") as f:
            f.seek(offset)
            data = f.read()
    except Exception:
        return [], offset

    last_newline = data.rfind(b"\n")
    if last_newline == -1:
        return [], offset  # no complete line yet -- don't advance, don't parse a partial one

    new_offset = offset + last_newline + 1
    events = []
    for line in data[:last_newline].split(b"\n"):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") != "assistant":
            continue
        content = (obj.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        ts = obj.get("timestamp")
        for block in content:
            if not (isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Bash"):
                continue
            cmd = (block.get("input") or {}).get("command")
            if isinstance(cmd, str):
                events.append((cmd, ts))
    return events, new_offset


def _update_state_from_new_events(state, transcript_path):
    """Shared by Stop and SessionEnd: advance the offset, and flip
    saw_session_start/saw_session_end the first time each is observed.
    session_start_ts is captured only on the transition to True, so it holds
    the moment session_start first happened, not the latest scan time."""
    events, new_offset = scan_new_bash_events(transcript_path, state.get("offset", 0))
    for cmd, ts in events:
        if not state.get("saw_session_start") and SESSION_START_PRESENT_RE.search(cmd):
            state["saw_session_start"] = True
            state["session_start_ts"] = ts
        if not state.get("saw_session_end") and SESSION_END_PRESENT_RE.search(cmd):
            state["saw_session_end"] = True
    state["offset"] = new_offset


def _now_iso():
    """Current UTC time in the same format as transcript timestamps, for a
    backstop-generated session_start that has no transcript Bash call to
    read a timestamp from."""
    return datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _parse_ts(ts):
    """Parses both the transcript's millisecond-precision timestamps
    ('2026-08-10T20:45:51.303Z') and the local log's second-precision ones
    ('2026-08-10T20:44:33Z') -- confirmed against real output of both."""
    if not ts:
        return None
    ts = ts.strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.strptime(ts, fmt)
        except ValueError:
            continue
    return None


def _read_log_lines():
    try:
        with open(LOG_FILE, "r", errors="ignore") as f:
            return f.readlines()
    except Exception:
        return []


def find_log_session_id(event, near_ts, window_seconds=CORRELATION_WINDOW_SECONDS):
    """The literal session_id telemetry-emit.sh actually logged for `event`,
    at a log-line timestamp within window_seconds of near_ts. Returns None on
    zero or more-than-one candidates -- ambiguity means "do nothing," same
    philosophy as the presence-only transcript scan above. This is what
    recovers the shell-variable case (session_id=$SESSION_ID): the log always
    has the real resolved id regardless of how the LLM constructed it."""
    near = _parse_ts(near_ts)
    if near is None:
        return None
    candidates = []
    for line in _read_log_lines():
        m = LOG_LINE_RE.match(line.strip())
        if not m or m.group("event") != event or not m.group("sid"):
            continue
        ts = _parse_ts(m.group("ts"))
        if ts is not None and abs((ts - near).total_seconds()) <= window_seconds:
            candidates.append(m.group("sid"))
    return candidates[0] if len(candidates) == 1 else None


def log_has_event_for(sid, event):
    for line in _read_log_lines():
        m = LOG_LINE_RE.match(line.strip())
        if m and m.group("event") == event and m.group("sid") == sid:
            return True
    return False


def emit(event, **fields):
    if not TELEMETRY_SCRIPT.is_file():
        return  # caller opted out -- silent no-op, same contract as SKILL.md's own emits
    args = [f"{k}={v}" for k, v in fields.items() if v not in (None, "")]
    try:
        subprocess.run(["bash", str(TELEMETRY_SCRIPT), event, *args], timeout=5, capture_output=True)
    except Exception:
        pass  # a backstop must never be able to break the session it's backstopping


def handle_stop(hook):
    claude_session_id = hook.get("session_id")
    transcript_path = hook.get("transcript_path")
    path = state_path(claude_session_id)
    if not path or not transcript_path:
        return

    state = load_state(path)
    if state is None:
        if not looks_like_thememate_session(transcript_path):
            save_state(path, {"is_thememate": False})
            return
        state = fresh_state()
    elif not state.get("is_thememate") or state.get("done"):
        return

    _update_state_from_new_events(state, transcript_path)
    state["stop_count"] = state.get("stop_count", 0) + 1

    elapsed = time.time() - state.get("marker_ts", time.time())
    if (
        not state.get("saw_session_start")
        and state["stop_count"] >= GRACE_MIN_STOPS
        and elapsed >= GRACE_MIN_SECONDS
    ):
        uid = str(uuid.uuid4())
        emit("session_start", session_id=uid, role="unknown", logged_by="stop_hook")
        state["saw_session_start"] = True
        state["session_start_ts"] = _now_iso()

    save_state(path, state)


def handle_session_end(hook):
    claude_session_id = hook.get("session_id")
    transcript_path = hook.get("transcript_path")
    path = state_path(claude_session_id)
    if not path or not transcript_path:
        return

    state = load_state(path)
    if state is None or not state.get("is_thememate") or state.get("done"):
        return

    _update_state_from_new_events(state, transcript_path)

    duration_min = int((time.time() - state.get("marker_ts", time.time())) / 60)
    turns = state.get("stop_count", 0)

    if not state.get("saw_session_start"):
        # Nothing ever started -- not even the Stop-hook's own grace-period
        # backstop got far enough (a very short session). This is the one
        # case with no identity ambiguity: the uuid is entirely ours, so we
        # can safely emit both ends of the pair ourselves.
        uid = str(uuid.uuid4())
        emit("session_start", session_id=uid, role="unknown", logged_by="stop_hook")
        emit(
            "session_end", session_id=uid, outcome="unknown", turns=turns,
            session_duration_min=duration_min, logged_by="session_end_hook",
        )
    elif state.get("saw_session_end"):
        pass  # LLM handled both ends itself -- nothing to do
    else:
        # session_start happened but session_end didn't. Resolve the real
        # session_id by correlating this session's own session_start moment
        # against the local telemetry log (recovers the shell-variable case
        # a transcript-text scan never could -- see module docstring).
        uid = find_log_session_id("session_start", state.get("session_start_ts") or "")
        if uid and log_has_event_for(uid, "session_end"):
            uid = None  # already closed -- e.g. the LLM's own session_end landed after our last scan
        if uid:
            # Deliberately omit summary/role/mode/store_domain -- absence
            # lets Code.gs's upsert-merge preserve whatever the LLM's own
            # last session_heartbeat already wrote in those columns, instead
            # of blanking them.
            emit(
                "session_end", session_id=uid, outcome="unknown", turns=turns,
                session_duration_min=duration_min, logged_by="session_end_hook",
            )
        # else: nothing safe to close client-side -- reconcileStaleSessions_
        # (Code.gs) still catches it.

    state["done"] = True
    save_state(path, state)  # kept, not deleted -- skill-updater.sh GCs old state files by mtime


def main():
    hook = read_hook_input()
    event = hook.get("hook_event_name")
    if event == "Stop":
        handle_stop(hook)
    elif event == "SessionEnd":
        handle_session_end(hook)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
