#!/bin/bash
# Swym skill auto-updater.
# Installed to ~/.claude/skill-updater.sh by install.sh.
# Runs via Claude Code UserPromptSubmit hook -- at most once per calendar day.
#
# For each skill in ~/.claude/skills/:
#   - If not in repo: skip (unmanaged skill)
#   - If version matches: skip
#   - If repo has newer version: overwrite local copy
#
# Also syncs telemetry-emit.sh and this script itself from the repo, by
# content diff rather than a version string (neither is version-tagged like
# SKILL.md) -- otherwise those two files would never update on an existing
# install, only on a fresh `install.sh` run.

REPO="swym-corp-custom-solutions/claude-skills"
SKILLS_DIR="$HOME/.claude/skills"
SELF_PATH="$HOME/.claude/skill-updater.sh"
LOCK_FILE="/tmp/swym-skill-check-$(date +%Y%m%d).lock"
HEARTBEAT_LOCK="/tmp/swym-thememate-heartbeat-$(date +%Y%m%d).lock"
TELEMETRY_OPTOUT_MARKER="$HOME/.claude/.thememate-telemetry-optout"
SYNC_SHA_CACHE="$HOME/.claude/.thememate-sync-shas"

# Only run once per calendar day
[ -f "$LOCK_FILE" ] && exit 0

# Fetch a single file from the repo and overwrite the local copy if its
# content actually differs. skill-updater.sh and telemetry-emit.sh aren't
# version-tagged like SKILL.md, so content diff is the only way to tell.
# Self-update is safe even though it overwrites the file this process is
# currently executing: `mv` is a rename, not an in-place write, and this
# already-running bash process keeps reading its already-open file
# descriptor's original inode content regardless -- POSIX rename semantics,
# not something specific to this script.
sync_file_from_repo() {
  local remote_path="$1" local_path="$2"
  local tmp
  tmp=$(mktemp)
  gh api "repos/$REPO/contents/$remote_path?ref=main" \
    --jq '.content | gsub("\n";"") | @base64d' > "$tmp" 2>/dev/null
  if [ -s "$tmp" ] && ! cmp -s "$tmp" "$local_path" 2>/dev/null; then
    mv "$tmp" "$local_path"
    chmod +x "$local_path"
    echo "[skill-updater] updated $(basename "$local_path")"
  else
    rm -f "$tmp"
  fi
}

# sync_file_from_repo always pays for a full content fetch, whether or not
# the file actually changed -- wasteful to do daily for two files that rarely
# change. This isn't tied to SKILL.md's version (infra-only fixes to these
# two files don't always come with a skill version bump -- this self-update
# mechanism itself is an example), so a single lightweight directory-listing
# call (populated below, after the gh-CLI gate) checks each file's git blob
# SHA first; only a file whose SHA actually changed pays for the full fetch.
sync_if_sha_changed() {
  local name="$1" local_path="$2"
  local remote_sha cached_sha
  remote_sha=$(printf '%s\n' "$REMOTE_SHAS" | grep "^$name=" | cut -d= -f2)
  [ -n "$remote_sha" ] || return 0
  cached_sha=$(grep "^$name=" "$SYNC_SHA_CACHE" 2>/dev/null | cut -d= -f2)
  [ "$remote_sha" = "$cached_sha" ] && return 0
  sync_file_from_repo "$name" "$local_path"
  # Cache the new SHA regardless of whether content actually changed --
  # sync_file_from_repo's own cmp is the correctness backstop; this cache
  # exists purely to skip tomorrow's fetch when nothing changed.
  { grep -v "^$name=" "$SYNC_SHA_CACHE" 2>/dev/null; echo "$name=$remote_sha"; } > "$SYNC_SHA_CACHE.tmp" 2>/dev/null
  mv "$SYNC_SHA_CACHE.tmp" "$SYNC_SHA_CACHE" 2>/dev/null
}

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
  # Best-effort, no LLM involved -- same opportunistic local-identity lookup
  # SKILL.md's GITHUB_SETUP uses, plus the cached one-time account_name
  # answer, so idle installs (skill-updater runs daily regardless of whether
  # ThemeMate itself is used) still carry an identity signal. Either can
  # resolve empty; telemetry-emit.sh drops empty values.
  HEARTBEAT_EMAIL=$(gh api user --jq '.email' 2>/dev/null)
  [ -n "$HEARTBEAT_EMAIL" ] || HEARTBEAT_EMAIL=$(git config user.email 2>/dev/null)
  HEARTBEAT_EMAIL_DOMAIN="${HEARTBEAT_EMAIL##*@}"
  [ "$HEARTBEAT_EMAIL_DOMAIN" = "$HEARTBEAT_EMAIL" ] && HEARTBEAT_EMAIL_DOMAIN=""
  HEARTBEAT_ACCOUNT_NAME=$(cat "$HOME/.claude/.thememate-account-name" 2>/dev/null)
  [ "$HEARTBEAT_ACCOUNT_NAME" = "skip" ] && HEARTBEAT_ACCOUNT_NAME=""
  bash "$TELEMETRY_SCRIPT" heartbeat email_domain="$HEARTBEAT_EMAIL_DOMAIN" account_name="$HEARTBEAT_ACCOUNT_NAME" >/dev/null 2>&1
fi

# Requires gh CLI -- check before burning the day's lock
command -v gh &>/dev/null || exit 0
command -v python3 &>/dev/null || exit 0

touch "$LOCK_FILE"

# One lightweight call for both files' current SHAs -- see sync_if_sha_changed's
# comment above.
REMOTE_SHAS=$(gh api "repos/$REPO/contents?ref=main" \
  --jq '.[] | select(.name == "telemetry-emit.sh" or .name == "skill-updater.sh") | "\(.name)=\(.sha)"' 2>/dev/null)

# --- Sync telemetry-emit.sh ---------------------------------------------
# Respects the permanent opt-out marker exactly like install.sh does. A bare
# `rm` of the file without that marker is only ever documented as an opt-out
# for "one install" (see install.sh) -- so it's expected, not a bug, that a
# newer version reappears here if the marker isn't set.
if [ ! -f "$TELEMETRY_OPTOUT_MARKER" ]; then
  sync_if_sha_changed "telemetry-emit.sh" "$TELEMETRY_SCRIPT"
fi

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

# --- Self-update: skill-updater.sh --------------------------------------
# Done last, after everything else this run needs -- see sync_file_from_repo's
# comment above for why overwriting the file this process is executing is safe.
sync_if_sha_changed "skill-updater.sh" "$SELF_PATH"
