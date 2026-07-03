#!/bin/bash
# Swym ThemeMate usage telemetry.
# Installed to ~/.claude/telemetry-emit.sh by install.sh.
#
# Called from two places:
#   - skill-updater.sh -- deterministic daily "heartbeat" (no LLM involved)
#   - SKILL.md          -- rich, best-effort session_start/session_end events
#
# Contract: NEVER blocks, NEVER errors loudly, NEVER retries. Telemetry must
# never affect the actual ThemeMate task -- always exits 0.
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
ENDPOINT_URL="https://script.google.com/macros/s/AKfycbzoweb5AaoAjyWvpinTYDcUmkzxZaMqYdtMAcnt6uH5usd3q_BlQox1pYlZNubIGQAr/exec"
TOKEN="1fdc121662ef8f7c74e17600771787e3"

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

SKILL_VERSION=$(grep -m1 "^  version:" "$HOME/.claude/skills/swym-thememate/SKILL.md" 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

# Remaining args are key=value pairs -- passed through argv so no
# shell-escaping of LLM-supplied values is needed to build valid JSON.
# Whitelisted keys + closed enums + a length cap keep this a fixed-shape,
# bounded-size payload even though the caller (an LLM) is not fully trusted --
# unknown keys, out-of-enum values, and oversized values are dropped, not sent.
PAYLOAD=$(python3 -c "
import json, sys

import re

MAX_LEN = 128
ALLOWED_KEYS = {
    'session_id', 'role', 'mode', 'platform', 'outcome',
    'failure_category', 'escalated_to', 'store_domain',
    'lines_written', 'satisfaction', 'feedback_reason', 'feedback_note',
    'git_org', 'git_repo', 'pr_url', 'preview_url', 'email_domain',
}
ENUMS = {
    'role': {'swym_acq', 'swym_success', 'swym_support', 'swym_staff', 'agency', 'merchant', 'unknown'},
    'mode': {'KNOWLEDGE', 'THEME_INSPECT', 'THEME_EDIT'},
    'platform': {'shopify', 'bigcommerce', 'headless', 'unknown'},
    'outcome': {'completed', 'blocked', 'error', 'scope_rejected'},
    'failure_category': {
        'app_embed_hidden', 'css_specificity_conflict', 'snippet_removed_on_update',
        'json_template_priority', 'callback_race_condition', 'zindex_stacking',
        'hot_reload_stale', 'non_theme_liquid_layout', 'theme_access_denied',
        'shopify_cli_auth_failure', 'push_failed', 'out_of_scope', 'other',
    },
    'escalated_to': {'swym_engineering', 'shopify_support', 'bigcommerce_support', 'none'},
    'satisfaction': {'positive', 'neutral', 'negative'},
    'feedback_reason': {
        'incorrect_output', 'didnt_solve_issue', 'too_slow',
        'unclear_explanation', 'other',
    },
}
# feedback_note is free text typed by an end user -- the one field here that
# isn't a closed enum. This is a best-effort backstop, not a guarantee: drop
# the whole note (rather than trying to redact in place) if it looks like it
# contains an email address or a long digit run (phone/order number shaped).
PII_PATTERNS = (
    re.compile(r'[\w.+-]+@[\w-]+\.[\w.-]+'),
    re.compile(r'\d{7,}'),
)
# email_domain must be a bare domain (e.g. 'acme.com'), never a full address --
# this is the hard backstop behind the 'strip before @ and discard it' instruction
# in SKILL.md, in case that step is ever skipped or done wrong.
EMAIL_DOMAIN_PATTERN = re.compile(r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$')

event, token, install_id, skill_version, ts = sys.argv[1:6]
fields = {
    'schema_version': 1,
    'skill': 'thememate',
    'skill_version': skill_version[:MAX_LEN],
    'install_id': install_id[:MAX_LEN],
    'event': event[:MAX_LEN],
    'ts': ts,
    'token': token,
}
for pair in sys.argv[6:]:
    if '=' not in pair:
        continue
    k, v = pair.split('=', 1)
    if k not in ALLOWED_KEYS:
        continue
    v = v[:MAX_LEN]
    if k in ENUMS and v not in ENUMS[k]:
        continue
    if k == 'feedback_note' and any(p.search(v) for p in PII_PATTERNS):
        continue
    if k == 'email_domain' and ('@' in v or not EMAIL_DOMAIN_PATTERN.match(v)):
        continue
    fields[k] = v
print(json.dumps(fields))
" "$EVENT" "$TOKEN" "$INSTALL_ID" "$SKILL_VERSION" "$TS" "$@" 2>/dev/null)

[ -n "$PAYLOAD" ] || exit 0

# Backgrounded and disowned so the caller never waits on network I/O -- a
# blocking `curl` here would contradict the "NEVER blocks" contract above,
# even bounded by --max-time.
( curl -sS -L --max-time 3 -X POST "$ENDPOINT_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" >/dev/null 2>&1 & disown ) 2>/dev/null

exit 0
