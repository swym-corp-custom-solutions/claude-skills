#!/bin/bash
# Swym Claude Skills installer.
#
# Run once from this repo root:
#   bash install.sh
#
# Check-only health report, changes nothing:
#   bash install.sh --doctor
#
# What it does:
#   1. Copies all skills from ./skills/ into ~/.claude/skills/
#   2. Installs the auto-updater script to ~/.claude/skill-updater.sh
#   3. Installs the ThemeMate telemetry backstop hook script to
#      ~/.claude/thememate-autolog.py
#   4. Wires hooks in ~/.claude/settings.json: UserPromptSubmit (daily skill
#      update check) plus Stop/SessionEnd (deterministic backstop for
#      ThemeMate usage telemetry the LLM's own emission can't guarantee)

set -e

DOCTOR_MODE=0
[ "$1" = "--doctor" ] && DOCTOR_MODE=1

# Preflight checks
command -v python3 &>/dev/null || {
  echo "Error: python3 is required to configure the Claude Code hook."
  echo "Install Python 3 from https://python.org and re-run this script."
  exit 1
}

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_SRC="$REPO_DIR/skills"
SKILLS_DEST="$HOME/.claude/skills"
UPDATER_SRC="$REPO_DIR/skill-updater.sh"
UPDATER_DEST="$HOME/.claude/skill-updater.sh"
TELEMETRY_SRC="$REPO_DIR/telemetry-emit.sh"
TELEMETRY_DEST="$HOME/.claude/telemetry-emit.sh"
TELEMETRY_OPTOUT_MARKER="$HOME/.claude/.thememate-telemetry-optout"
AUTOLOG_SRC="$REPO_DIR/thememate-autolog.py"
AUTOLOG_DEST="$HOME/.claude/thememate-autolog.py"
HOOKS_LIB_SRC="$REPO_DIR/thememate-hooks.py"
HOOKS_LIB_DEST="$HOME/.claude/thememate-hooks.py"

if [ "$DOCTOR_MODE" = "1" ]; then
  echo "Swym Claude Skills doctor (check-only, changes nothing)"
  echo "========================================================"
  echo ""
  STATUS=0

  for skill_dir in "$SKILLS_SRC"/*/; do
    name="$(basename "$skill_dir")"
    if [ -f "$HOME/.claude/skills/$name/SKILL.md" ]; then
      local_version=$(grep -m1 "^  version:" "$HOME/.claude/skills/$name/SKILL.md" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
      repo_version=$(grep -m1 "^  version:" "$skill_dir/SKILL.md" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
      if [ "$local_version" = "$repo_version" ]; then
        echo "  ok    $name installed ($local_version, matches repo)"
      else
        echo "  WARN  $name installed ($local_version) -- repo has $repo_version, will sync on next daily check"
      fi
    else
      echo "  FAIL  $name not installed"
      STATUS=1
    fi
  done

  for f in "$UPDATER_DEST" "$HOOKS_LIB_DEST"; do
    if [ -f "$f" ]; then
      echo "  ok    $(basename "$f") present"
    else
      echo "  FAIL  $(basename "$f") NOT installed"
      STATUS=1
    fi
  done

  if [ -f "$TELEMETRY_OPTOUT_MARKER" ]; then
    echo "  ok    telemetry opted out ($TELEMETRY_OPTOUT_MARKER present) -- emitter/backstop intentionally absent"
  else
    for f in "$TELEMETRY_DEST" "$AUTOLOG_DEST"; do
      if [ -f "$f" ]; then
        echo "  ok    $(basename "$f") present"
      else
        echo "  FAIL  $(basename "$f") NOT installed"
        STATUS=1
      fi
    done
  fi

  echo ""
  echo "Hook registration:"
  if [ -f "$HOOKS_LIB_DEST" ]; then
    python3 "$HOOKS_LIB_DEST" check || STATUS=1
  elif [ -f "$HOOKS_LIB_SRC" ]; then
    python3 "$HOOKS_LIB_SRC" check || STATUS=1
  else
    echo "  FAIL  thememate-hooks.py not found -- cannot check hook registration"
    STATUS=1
  fi

  echo ""
  if [ "$STATUS" = "0" ]; then
    echo "All checks passed."
  else
    echo "One or more checks failed -- re-run 'bash install.sh' (without --doctor) to fix."
  fi
  exit $STATUS
fi

echo "Swym Claude Skills installer"
echo "================================"

# --- 1. Install skills -------------------------------------------------
echo ""
echo "Installing skills..."
mkdir -p "$SKILLS_DEST"

for skill_dir in "$SKILLS_SRC"/*/; do
  skill_name="$(basename "$skill_dir")"
  dest="$SKILLS_DEST/$skill_name"
  mkdir -p "$dest"
  cp "$skill_dir/SKILL.md" "$dest/SKILL.md"
  version=$(grep -m1 "^  version:" "$dest/SKILL.md" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
  echo "  installed $skill_name ($version)"
done

# --- 2. Install auto-updater -------------------------------------------
echo ""
echo "Installing auto-updater..."
cp "$UPDATER_SRC" "$UPDATER_DEST"
chmod +x "$UPDATER_DEST"
echo "  installed $UPDATER_DEST"

# --- 2b. Install telemetry emitter --------------------------------------
echo ""
if [ -f "$TELEMETRY_OPTOUT_MARKER" ]; then
  echo "Skipping telemetry emitter -- opt-out marker found at $TELEMETRY_OPTOUT_MARKER"
  rm -f "$TELEMETRY_DEST"
else
  echo "Installing telemetry emitter..."
  cp "$TELEMETRY_SRC" "$TELEMETRY_DEST"
  chmod +x "$TELEMETRY_DEST"
  echo "  installed $TELEMETRY_DEST"
  echo "  Opt out any time:"
  echo "    - one install:  rm $TELEMETRY_DEST"
  echo "    - permanently:  touch $TELEMETRY_OPTOUT_MARKER  (survives future installs/updates)"
fi

# --- 2c. Install telemetry backstop hook script -------------------------
# Same opt-out gate as the emitter above -- its whole purpose is telemetry,
# so it has nothing to do once opted out (its own emit() calls also already
# no-op if telemetry-emit.sh is missing, but skip installing it entirely
# rather than leaving a hook registered that never does anything).
echo ""
if [ -f "$TELEMETRY_OPTOUT_MARKER" ]; then
  rm -f "$AUTOLOG_DEST"
else
  echo "Installing telemetry backstop hook script..."
  cp "$AUTOLOG_SRC" "$AUTOLOG_DEST"
  chmod +x "$AUTOLOG_DEST"
  echo "  installed $AUTOLOG_DEST"
fi

# --- 2d. Install shared hook-registration library -----------------------
echo ""
echo "Installing hook-registration library..."
cp "$HOOKS_LIB_SRC" "$HOOKS_LIB_DEST"
chmod +x "$HOOKS_LIB_DEST"
echo "  installed $HOOKS_LIB_DEST"

# --- 3. Wire Claude Code hooks ------------------------------------------
# thememate-hooks.py owns the "which hooks are expected" list and the safe
# read-backup-write-validate sequence (see that file's own docstring) --
# used here, by skill-updater.sh's daily self-heal, and by --doctor above,
# so all three read the same definition instead of three copies that could
# drift out of sync with each other.
echo ""
echo "Configuring Claude Code hooks..."
python3 "$HOOKS_LIB_DEST" sync

echo ""
echo "Done. Start a new Claude Code session to activate."
echo "On first prompt each day, Claude will check for skill updates automatically."
echo "Run 'bash install.sh --doctor' anytime to check this install's health."
