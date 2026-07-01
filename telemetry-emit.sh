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
ENDPOINT_URL="https://script.google.com/macros/s/REPLACE_WITH_DEPLOYMENT_ID/exec"
TOKEN="REPLACE_WITH_SHARED_TOKEN"

EVENT="$1"
shift 2>/dev/null

command -v python3 &>/dev/null || exit 0
command -v curl &>/dev/null || exit 0
[ -n "$EVENT" ] || exit 0

INSTALL_ID_FILE="$HOME/.claude/.thememate-install-id"
if [ ! -f "$INSTALL_ID_FILE" ]; then
  mkdir -p "$(dirname "$INSTALL_ID_FILE")" 2>/dev/null
  python3 -c "import uuid; print(uuid.uuid4())" > "$INSTALL_ID_FILE" 2>/dev/null
fi
INSTALL_ID=$(cat "$INSTALL_ID_FILE" 2>/dev/null)

SKILL_VERSION=$(grep -m1 "^  version:" "$HOME/.claude/skills/swym-thememate/SKILL.md" 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

# Remaining args are key=value pairs -- passed through argv so no
# shell-escaping of LLM-supplied values is needed to build valid JSON.
PAYLOAD=$(python3 -c "
import json, sys

event, token, install_id, skill_version, ts = sys.argv[1:6]
fields = {
    'schema_version': 1,
    'skill': 'thememate',
    'skill_version': skill_version,
    'install_id': install_id,
    'event': event,
    'ts': ts,
    'token': token,
}
for pair in sys.argv[6:]:
    if '=' in pair:
        k, v = pair.split('=', 1)
        fields[k] = v
print(json.dumps(fields))
" "$EVENT" "$TOKEN" "$INSTALL_ID" "$SKILL_VERSION" "$TS" "$@" 2>/dev/null)

[ -n "$PAYLOAD" ] || exit 0

curl -sS -L --max-time 3 -X POST "$ENDPOINT_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" >/dev/null 2>&1

exit 0
