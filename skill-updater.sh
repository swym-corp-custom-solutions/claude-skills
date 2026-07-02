#!/bin/bash
# Swym skill auto-updater.
# Installed to ~/.claude/skill-updater.sh by install.sh.
# Runs via Claude Code UserPromptSubmit hook -- at most once per calendar day.
#
# For each skill in ~/.claude/skills/:
#   - If not in repo: skip (unmanaged skill)
#   - If version matches: skip
#   - If repo has newer version: overwrite local copy

REPO="swym-corp-custom-solutions/claude-skills"
SKILLS_DIR="$HOME/.claude/skills"
LOCK_FILE="/tmp/swym-skill-check-$(date +%Y%m%d).lock"
HEARTBEAT_LOCK="/tmp/swym-thememate-heartbeat-$(date +%Y%m%d).lock"

# Only run once per calendar day
[ -f "$LOCK_FILE" ] && exit 0

# --- Telemetry heartbeat (deterministic, no gh required) ---------------
# Fires at most once per calendar day, on its own lock, so it still runs on
# machines with no gh CLI (e.g. merchants) even though the update check below
# exits early for them. Never blocks the rest of this script.
TELEMETRY_SCRIPT="$HOME/.claude/telemetry-emit.sh"
# Gate on the script's existence too -- claiming today's lock when the script
# is missing would make opt-out (deleting telemetry-emit.sh) a non-op AND
# block heartbeat for the rest of the day if the user restores it.
if [ -f "$TELEMETRY_SCRIPT" ] && [ ! -f "$HEARTBEAT_LOCK" ]; then
  touch "$HEARTBEAT_LOCK" 2>/dev/null
  bash "$TELEMETRY_SCRIPT" heartbeat >/dev/null 2>&1
fi

# Requires gh CLI -- check before burning the day's lock
command -v gh &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0

touch "$LOCK_FILE"

# Discover all skills published to the repo's main branch
SKILL_NAMES=$(gh api "repos/$REPO/contents/skills?ref=main" \
  --jq '.[].name' 2>/dev/null)
[ -z "$SKILL_NAMES" ] && exit 0

while IFS= read -r SKILL_NAME; do
  REMOTE_PATH="skills/$SKILL_NAME/SKILL.md"
  LOCAL_SKILL="$SKILLS_DIR/$SKILL_NAME/SKILL.md"

  # Fetch and decode remote SKILL.md via jq @base64d (portable -- no base64 binary needed)
  REMOTE_TMP=$(mktemp)
  gh api "repos/$REPO/contents/$REMOTE_PATH?ref=main" \
    --jq '.content | gsub("\n";"") | @base64d' > "$REMOTE_TMP" 2>/dev/null
  [ -s "$REMOTE_TMP" ] || { rm -f "$REMOTE_TMP"; continue; }

  REMOTE_VERSION=$(grep -m1 "^  version:" "$REMOTE_TMP" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

  # --- Install (first time) ---
  if [ ! -f "$LOCAL_SKILL" ]; then
    mkdir -p "$(dirname "$LOCAL_SKILL")"
    cp "$REMOTE_TMP" "$LOCAL_SKILL"
    echo "[skill-updater] installed $SKILL_NAME ${REMOTE_VERSION:-unknown}"
    rm -f "$REMOTE_TMP"
    continue
  fi

  # --- Update (version check) ---
  LOCAL_VERSION=$(grep -m1 "^  version:" "$LOCAL_SKILL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$LOCAL_VERSION" ] || [ -z "$REMOTE_VERSION" ]; then
    rm -f "$REMOTE_TMP"; continue
  fi
  if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
    rm -f "$REMOTE_TMP"; continue
  fi

  # Skip if local is already ahead (python3 semver -- portable, no sort -V needed)
  IS_NEWER=$(python3 -c "
a = tuple(int(x) for x in '$REMOTE_VERSION'.split('.'))
b = tuple(int(x) for x in '$LOCAL_VERSION'.split('.'))
print('yes' if a > b else 'no')
" 2>/dev/null)
  if [ "$IS_NEWER" != "yes" ]; then
    rm -f "$REMOTE_TMP"; continue
  fi

  cp "$REMOTE_TMP" "$LOCAL_SKILL"
  rm -f "$REMOTE_TMP"
  echo "[skill-updater] updated $SKILL_NAME $LOCAL_VERSION -> $REMOTE_VERSION"

done <<< "$SKILL_NAMES"
