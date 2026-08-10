#!/bin/bash
# Swym ThemeMate usage telemetry.
# Installed to ~/.claude/telemetry-emit.sh by install.sh.
#
# Called from two places:
#   - skill-updater.sh -- deterministic daily "heartbeat" (no LLM involved)
#   - SKILL.md          -- rich, best-effort session_start/session_end events
#
# Contract: NEVER blocks, NEVER errors loudly. Telemetry must never affect
# the actual ThemeMate task -- always exits 0. Delivery itself DOES retry
# (queued locally on failure, drained on the next successful send) -- see
# the send step near the bottom of this file for why.
#
# Usage: telemetry-emit.sh <event_type> [key=value ...]
# Example:
#   bash ~/.claude/telemetry-emit.sh session_start role=swym_acq mode=THEME_EDIT session_id=1c2e...
#
# Opt out: delete this file. Callers must treat a missing file as a silent no-op.

# --- Configuration ----------------------------------------------------
# Filled in during the one-time Google Sheet + Apps Script setup (see
# CHANGELOG.md / README.md "Telemetry & privacy"). Not a secret boundary --
# no PII ever travels through this endpoint.
ENDPOINT_URL="https://script.google.com/macros/s/AKfycbwx-NhbUZmKukNpKAvGC2I5-CIqTCH1xKlcIIQDWuO4305CZAYCJx9auYtEoKqK262S/exec"
TOKEN="1fdc121662ef8f7c74e17600771787e3"
FALLBACK_FILE="$HOME/.claude/.thememate-usage-fallback.jsonl"

EVENT="$1"
shift 2>/dev/null

command -v python3 &>/dev/null || exit 0
command -v curl &>/dev/null || exit 0
[ -n "$EVENT" ] || exit 0

INSTALL_ID_FILE="$HOME/.claude/.thememate-install-id"
# -s (exists AND non-empty) catches both "never created" and "previous write
# failed/truncated" -- either way, regenerate rather than ship a blank id.
if [ ! -s "$INSTALL_ID_FILE" ]; then
  mkdir -p "$(dirname "$INSTALL_ID_FILE")" 2>/dev/null
  python3 -c "import uuid; print(uuid.uuid4())" > "$INSTALL_ID_FILE" 2>/dev/null
fi
INSTALL_ID=$(cat "$INSTALL_ID_FILE" 2>/dev/null)
[ -n "$INSTALL_ID" ] || exit 0

# Auto-attach account_name from cache, mirroring install_id above. SKILL.md
# asks for this once ever (gated on this same file not existing) but the
# answer must reach EVERY session's row, not just that first one -- upsert
# merge only carries a value across events sharing one session_id, never
# across different sessions (different session_id, different row). Centralizing
# the resend here means every caller benefits for free: SKILL.md's own emits,
# thememate-autolog.py's synthetic backstop emits (which have no way to know
# this value themselves), and skill-updater.sh's heartbeat all get it without
# doing anything extra. Only attaches if the caller didn't already pass one
# explicitly (the one-time ask flow still writes its answer straight through).
ACCOUNT_NAME_FILE="$HOME/.claude/.thememate-account-name"
if [ -s "$ACCOUNT_NAME_FILE" ] && ! printf '%s\n' "$@" | grep -q '^account_name='; then
  CACHED_ACCOUNT_NAME=$(cat "$ACCOUNT_NAME_FILE" 2>/dev/null)
  if [ -n "$CACHED_ACCOUNT_NAME" ] && [ "$CACHED_ACCOUNT_NAME" != "skip" ]; then
    set -- "$@" "account_name=$CACHED_ACCOUNT_NAME"
  fi
fi

# Manual test pings (e.g. verifying a Sheet/Apps Script change) otherwise land
# in the same sheet as real usage with no way to filter them out. Marker file,
# same pattern as install.sh's telemetry opt-out marker -- `touch` it before
# testing, `rm` it when done.
if [ -f "$HOME/.claude/.thememate-telemetry-debug" ]; then
  INSTALL_ID="debug-$INSTALL_ID"
fi

SKILL_VERSION=$(grep -m1 "^  version:" "$HOME/.claude/skills/swym-thememate/SKILL.md" 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

# BEGIN GENERATED TELEMETRY SCHEMA - DO NOT EDIT MANUALLY
SCHEMA_KEYS_JSON='["session_id", "role", "mode", "feature", "usecase", "platform", "outcome", "usecase_met", "failure_category", "escalated_to", "store_domain", "vertical", "lines_written", "turns", "tokens", "session_duration_min", "summary", "satisfaction", "feedback_reason", "feedback_note", "git_org", "git_repo", "pr_url", "preview_url", "email_domain", "account_name", "logged_by"]'
SCHEMA_ENUMS_JSON='{"role": ["swym_acq", "swym_success", "swym_support", "swym_staff", "agency", "merchant", "unknown"], "mode": ["KNOWLEDGE", "THEME_INSPECT", "THEME_EDIT"], "platform": ["shopify", "bigcommerce", "headless", "unknown"], "outcome": ["completed", "blocked", "error", "scope_rejected", "unknown"], "logged_by": ["llm", "stop_hook", "session_end_hook", "server_sweep"], "usecase_met": ["yes", "no"], "failure_category": ["app_embed_hidden", "css_specificity_conflict", "snippet_removed_on_update", "json_template_priority", "callback_race_condition", "zindex_stacking", "hot_reload_stale", "non_theme_liquid_layout", "theme_access_denied", "shopify_cli_auth_failure", "push_failed", "out_of_scope", "browser_automation_failure", "sfl_cart_toggle_disabled", "bis_stale_variant_binding", "bis_custom_webhook_unreachable", "unsupported_feature_requested", "other"], "escalated_to": ["swym_engineering", "shopify_support", "bigcommerce_support", "none"], "satisfaction": ["positive", "neutral", "negative"], "feedback_reason": ["incorrect_output", "didnt_solve_issue", "too_slow", "unclear_explanation", "other"]}'
SCHEMA_MAX_LEN='128'
SCHEMA_FIELD_MAX_LEN_JSON='{"summary": 400}'
SCHEMA_VERSION='1'
# END GENERATED TELEMETRY SCHEMA

# Remaining args are key=value pairs -- passed through argv so no
# shell-escaping of LLM-supplied values is needed to build valid JSON.
# Whitelisted keys + closed enums + a length cap keep this a fixed-shape,
# bounded-size payload even though the caller (an LLM) is not fully trusted --
# unknown keys, out-of-enum values, and oversized values are dropped, not sent.
PAYLOAD=$(python3 -c "
import json, sys

import re

keys_json, enums_json, max_len_str, field_max_len_json, schema_version_str = sys.argv[1:6]
MAX_LEN = int(max_len_str)
ALLOWED_KEYS = set(json.loads(keys_json))
ENUMS = {k: set(v) for k, v in json.loads(enums_json).items()}
# Per-field override on top of MAX_LEN -- e.g. summary gets more room to hold
# a running pointer-log of the whole session, without loosening the cap on
# higher-PII-risk free-text fields (feedback_note, account_name, usecase).
FIELD_MAX_LEN = {k: int(v) for k, v in json.loads(field_max_len_json).items()}
# feedback_note (user-typed), summary (LLM-written), account_name
# (user-typed), and usecase (LLM-paraphrased from the user's own request) are
# the free text fields here that aren't a closed enum. This is a best-effort
# backstop, not a guarantee: drop the whole value (rather than trying to
# redact in place) if it looks like it contains an email address (any '@' at
# all, including a partial local-part with no domain yet typed) or a long
# digit run (phone/order number shaped).
PII_PATTERNS = (
    re.compile(r'@'),
    re.compile(r'\d{7,}'),
)
FREE_TEXT_KEYS = ('feedback_note', 'summary', 'account_name', 'usecase')
# email_domain must be a bare domain (e.g. 'acme.com'), never a full address --
# this is the hard backstop behind the 'strip before @ and discard it' instruction
# in SKILL.md, in case that step is ever skipped or done wrong.
EMAIL_DOMAIN_PATTERN = re.compile(r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$')
# session_id must be the UUID SKILL.md's session_start step generates and asks
# the caller to reuse verbatim on every later event in the same session. A
# hand-typed/descriptive id (seen in the wild, e.g. 'tm-support-2026-07-03')
# can't be relied on to be reused consistently and silently breaks the
# session_start/session_end join downstream. Dropping just this field isn't
# enough -- every malformed id would then land with the same blank
# session_id, which is worse than unjoinable: a naive groupby would fold them
# all together as if they were one session. Drop the whole event instead.
SESSION_ID_PATTERN = re.compile(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')

event, token, install_id, skill_version, ts = sys.argv[6:11]
fields = {
    'schema_version': int(schema_version_str),
    'skill': 'thememate',
    'skill_version': skill_version[:MAX_LEN],
    'install_id': install_id[:MAX_LEN],
    'event': event[:MAX_LEN],
    'ts': ts,
    'token': token,
}
for pair in sys.argv[10:]:
    if '=' not in pair:
        continue
    k, v = pair.split('=', 1)
    if k not in ALLOWED_KEYS:
        continue
    v = v[:FIELD_MAX_LEN.get(k, MAX_LEN)]
    if k in ENUMS and v not in ENUMS[k]:
        continue
    if k in FREE_TEXT_KEYS and any(p.search(v) for p in PII_PATTERNS):
        continue
    if k == 'email_domain' and ('@' in v or not EMAIL_DOMAIN_PATTERN.match(v)):
        continue
    if k == 'session_id' and not SESSION_ID_PATTERN.match(v):
        sys.exit(0)
    # An accidental empty value (e.g. a caller passing key= with nothing
    # after it) would otherwise still land in fields and, downstream, count
    # as present on this event for the receiver's upsert merge -- blanking a
    # column a prior event in the same session had already set. session_id
    # is exempted above (empty already hard-fails the whole event, doesn't
    # fall through to here).
    if not v:
        continue
    fields[k] = v
print(json.dumps(fields))
" "$SCHEMA_KEYS_JSON" "$SCHEMA_ENUMS_JSON" "$SCHEMA_MAX_LEN" "$SCHEMA_FIELD_MAX_LEN_JSON" "$SCHEMA_VERSION" "$EVENT" "$TOKEN" "$INSTALL_ID" "$SKILL_VERSION" "$TS" "$@" 2>/dev/null)

[ -n "$PAYLOAD" ] || exit 0

# Local audit trail. The curl below is backgrounded/disowned and never
# checked for success, so without this there is no way on this machine to
# tell an event that was actually attempted apart from one silently dropped
# by validation above or lost to the network. Deliberately minimal (no PII,
# no payload contents): event, session_id, timestamp only. Rotated to the
# last 500 lines so it never grows unbounded.
#
# Locked (fcntl.flock, not the `flock` CLI -- not installed on macOS by
# default, but python3 is already a hard dependency of this script and its
# fcntl module gives the same guarantee on macOS and Linux alike) because two
# ThemeMate sessions emitting close together otherwise race on the
# append-then-rotate: A's `tail` snapshot happens before B's line lands, then
# A's rewrite clobbers it. Harmless while this log was purely a debug trail;
# thememate-autolog.py's SessionEnd handler now correlates against it to
# resolve a session's real session_id when the LLM used a shell variable
# rather than a literal UUID, so a lost line here is a lost closing
# opportunity, not just a cosmetic gap. The lock is released automatically if
# this process dies mid-write (OS-level, not a lockfile-existence check), so
# no separate timeout/staleness handling is needed.
LOG_FILE="$HOME/.claude/.thememate-telemetry.log"
SESSION_ID_LOGGED=$(printf '%s\n' "$@" | grep -m1 '^session_id=' | cut -d= -f2-)
(
  umask 077
  python3 -c "
import fcntl, sys
log_file, lock_file, ts, event, session_id = sys.argv[1:6]
try:
    with open(lock_file, 'a') as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            with open(log_file, 'a') as f:
                f.write('%s event=%s session_id=%s\n' % (ts, event, session_id))
            with open(log_file) as f:
                lines = f.readlines()[-500:]
            with open(log_file, 'w') as f:
                f.writelines(lines)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)
except Exception:
    pass
" "$LOG_FILE" "${LOG_FILE}.lock" "$TS" "$EVENT" "$SESSION_ID_LOGGED"
) 2>/dev/null
# Backstop: umask only governs newly-created files, so a log file left
# over from before this fix (or written by a process with a looser umask)
# needs an explicit tightening too, since it records timing/session_ids.
chmod 600 "$LOG_FILE" "${LOG_FILE}.lock" 2>/dev/null

# Backgrounded and disowned so the caller never waits on network I/O -- a
# blocking send here would contradict the "NEVER blocks" contract above,
# even at the longer timeout below.
#
# Delivery retries: a bare fire-and-forget POST (the old behavior) silently
# lost real, correctly-invoked events on a cold Apps Script instance --
# Google's own web apps commonly take several seconds to wake from idle, and
# the old 3s curl timeout gave that no margin at all. The 15s timeout here is
# safe to be this generous specifically because it was never actually
# bounding the caller's wait -- only this already-detached background
# process's -- so there's no new cost to the real ThemeMate task from
# lengthening it. On any failure (network error, timeout, or the receiver's
# own {"ok": false} -- Code.gs's jsonResponse_ always returns HTTP 200 even
# for a rejected token or a server exception, so the status code alone is
# not a trustworthy success signal, only the body is), the payload is queued
# to FALLBACK_FILE and retried on the next successful send from this
# machine, instead of being lost. Session-scoped events dedupe for free via
# Code.gs's session_id-keyed upsertRow_ merge if a queued send turns out to
# have actually landed the first time; no separate idempotency key needed.
#
# The actual send shells out to `curl` (via subprocess) rather than using
# python's own urllib -- confirmed live, not assumed: urllib/ssl on macOS's
# python.org-distributed Python does not use the system certificate trust
# store the way curl does, so it failed every single HTTPS request with a
# certificate-verification error until this fix, silently queueing 100% of
# real traffic to the fallback file. curl has always worked correctly here
# (it's what the pre-retry-queue version of this script used), so it keeps
# doing the actual network work; python only adds the response-body check,
# retry queue, and drain logic around it.
#
# Redirects are followed MANUALLY (a second, separate curl call to whatever
# the first response's Location header says), not via curl's own -L --
# confirmed live and reproducible: this curl build's HTTP/2 redirect
# handling mishandles the cross-host redirect Apps Script's webapp always
# issues (script.google.com -> script.googleusercontent.com), variously
# surfacing as a generic Google Drive 404 or (under --http1.1) an explicit
# \"411 Length Required\" -- i.e. curl replaying a malformed POST at the
# second hop instead of the plain GET that endpoint actually expects. Two
# independent curl invocations, with no method carried over between them,
# sidesteps whatever -L is doing wrong here entirely, and was 100% reliable
# across repeated live tests against production where -L failed every time.
(
  python3 -c "
import json, subprocess, sys
from pathlib import Path

endpoint, payload_json, fallback_file = sys.argv[1:4]
FALLBACK_CAP = 1000
MAX_DRAIN = 25

def _run_curl(args, input_bytes=None, timeout=15):
    result = subprocess.run(args, input=input_bytes, capture_output=True, timeout=timeout + 3)
    if result.returncode != 0:
        raise RuntimeError('curl exited %d: %s' % (result.returncode, result.stderr.decode('utf-8', 'replace')))
    return result.stdout

def post(payload_bytes, timeout=15):
    raw = _run_curl(
        ['curl', '-sS', '-D', '-', '--max-time', str(timeout), '-X', 'POST', endpoint,
         '-H', 'Content-Type: application/json', '--data-binary', '@-'],
        input_bytes=payload_bytes, timeout=timeout,
    )
    header_blob, sep, body = raw.partition(b'\r\n\r\n')
    if not sep:
        header_blob, sep, body = raw.partition(b'\n\n')
    location = None
    for line in header_blob.decode('utf-8', 'replace').splitlines():
        if line.lower().startswith('location:'):
            location = line.split(':', 1)[1].strip()
            break
    if location:
        body = _run_curl(['curl', '-sS', '--max-time', str(timeout), location], timeout=timeout)
    return body.decode('utf-8', 'replace')

def looks_ok(body):
    try:
        return bool(json.loads(body).get('ok'))
    except Exception:
        return False

def save_fallback(line):
    try:
        p = Path(fallback_file)
        p.parent.mkdir(parents=True, exist_ok=True)
        lines = p.read_text().splitlines() if p.is_file() else []
        lines.append(line)
        p.write_text('\n'.join(lines[-FALLBACK_CAP:]) + '\n')
        p.chmod(0o600)
    except Exception:
        pass

def drain_fallback():
    try:
        p = Path(fallback_file)
        if not p.is_file():
            return
        lines = [ln for ln in p.read_text().splitlines() if ln.strip()]
        sent = 0
        for i, line in enumerate(lines):
            if sent >= MAX_DRAIN:
                break
            try:
                ok = looks_ok(post(line.encode('utf-8')))
            except Exception:
                ok = False
            if not ok:
                break
            sent += 1
            # Truncate after EACH delivery, not after the whole loop -- an
            # interrupted drain must not re-send what it already delivered.
            rest = lines[i + 1:]
            if rest:
                p.write_text('\n'.join(rest) + '\n')
            elif p.is_file():
                p.unlink()
    except Exception:
        pass

payload_bytes = payload_json.encode('utf-8')
try:
    ok = looks_ok(post(payload_bytes))
except Exception:
    ok = False

if ok:
    drain_fallback()
else:
    save_fallback(payload_json)
" "$ENDPOINT_URL" "$PAYLOAD" "$FALLBACK_FILE" >/dev/null 2>&1 &
  disown
) 2>/dev/null

exit 0
