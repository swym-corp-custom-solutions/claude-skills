#!/bin/bash
# Swym Claude Skills installer.
#
# Run once from this repo root:
#   bash install.sh
#
# What it does:
#   1. Copies all skills from ./skills/ into ~/.claude/skills/
#   2. Installs the auto-updater script to ~/.claude/skill-updater.sh
#   3. Wires a UserPromptSubmit hook in ~/.claude/settings.json so skills
#      stay up to date automatically (daily check against GitHub main).

set -e

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
SETTINGS="$HOME/.claude/settings.json"

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

# --- 3. Wire Claude Code hook -----------------------------------------
echo ""
echo "Configuring Claude Code hook..."

if [ ! -f "$SETTINGS" ]; then
  echo "{}" > "$SETTINGS"
fi

# Use python3 to safely merge the hook into existing settings JSON
python3 - "$SETTINGS" <<'PYEOF'
import json, sys

path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)

hook_command = "bash $HOME/.claude/skill-updater.sh"
hook_entry = {"type": "command", "command": hook_command}
hook_block = {"matcher": "", "hooks": [hook_entry]}

hooks = settings.setdefault("hooks", {})
submit_hooks = hooks.setdefault("UserPromptSubmit", [])

# Avoid duplicate entries
already_wired = any(
    any(h.get("command") == hook_command for h in block.get("hooks", []))
    for block in submit_hooks
)

if not already_wired:
    submit_hooks.append(hook_block)
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
    print("  hook added to", path)
else:
    print("  hook already present -- skipped")
PYEOF

echo ""
echo "Done. Start a new Claude Code session to activate."
echo "On first prompt each day, Claude will check for skill updates automatically."
