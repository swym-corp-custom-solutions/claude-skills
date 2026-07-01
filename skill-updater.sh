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

# Only run once per calendar day
[ -f "$LOCK_FILE" ] && exit 0
touch "$LOCK_FILE"

# Requires gh CLI to be authenticated
command -v gh &>/dev/null || exit 0

# Discover all skills published to the repo's main branch
SKILL_NAMES=$(gh api "repos/$REPO/contents/skills?ref=main" \
  --jq '.[].name' 2>/dev/null)
[ -z "$SKILL_NAMES" ] && exit 0

while IFS= read -r SKILL_NAME; do
  REMOTE_PATH="skills/$SKILL_NAME/SKILL.md"
  LOCAL_SKILL="$SKILLS_DIR/$SKILL_NAME/SKILL.md"

  # Fetch remote SKILL.md content from main branch
  REMOTE_CONTENT=$(gh api "repos/$REPO/contents/$REMOTE_PATH?ref=main" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
  [ -z "$REMOTE_CONTENT" ] && continue

  REMOTE_VERSION=$(echo "$REMOTE_CONTENT" | grep -m1 "^  version:" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

  # --- Install (first time) ---
  if [ ! -f "$LOCAL_SKILL" ]; then
    mkdir -p "$(dirname "$LOCAL_SKILL")"
    echo "$REMOTE_CONTENT" > "$LOCAL_SKILL"
    echo "[skill-updater] installed $SKILL_NAME ${REMOTE_VERSION:-unknown}"
    continue
  fi

  # --- Update (version check) ---
  LOCAL_VERSION=$(grep -m1 "^  version:" "$LOCAL_SKILL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$LOCAL_VERSION" ] || [ -z "$REMOTE_VERSION" ]; then continue; fi
  [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ] && continue

  # Skip if local is already ahead
  NEWER=$(printf '%s\n%s\n' "$LOCAL_VERSION" "$REMOTE_VERSION" | sort -V | tail -1)
  [ "$NEWER" = "$LOCAL_VERSION" ] && continue

  echo "$REMOTE_CONTENT" > "$LOCAL_SKILL"
  echo "[skill-updater] updated $SKILL_NAME $LOCAL_VERSION -> $REMOTE_VERSION"

done <<< "$SKILL_NAMES"
