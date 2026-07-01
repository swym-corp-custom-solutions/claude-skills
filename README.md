# Swym Claude Skills

Claude Code skills used by the Swym ACQ and solutions team. Each skill is a self-contained directory under `skills/` that gets installed into `~/.claude/skills/` on your local machine.

---

## Available Skills

| Skill | Invocation | Description |
|-------|-----------|-------------|
| [ThemeMate](skills/swym-shopify-thememate-theme-editor/) | `/thememate` | Implement and debug Swym Wishlist UI on Shopify storefronts |

---

## ThemeMate

ThemeMate turns Claude Code into an expert Shopify theme assistant for Swym. You describe what needs to change on a merchant storefront and ThemeMate handles the full workflow: pulling the theme locally, exploring the file structure, implementing the change, running local browser validation, and opening a PR for review.

**No MCP server required.** ThemeMate uses the Shopify CLI and standard file tools directly.

---

### Prerequisites

All of the following must be installed and authenticated before ThemeMate can run.

**1. Claude Code**
```bash
npm install -g @anthropic-ai/claude-code
claude login
```

**2. Node.js 18 or later**
```bash
node --version   # must be >= 18.0.0
```
If not: install via [nvm](https://github.com/nvm-sh/nvm) or the Node.js website.

**3. Shopify CLI**
```bash
npm install -g @shopify/cli@latest
shopify auth login   # log in with your Shopify Partner account
```

**4. GitHub CLI**
```bash
brew install gh
gh auth login
```
Must have access to the `swym-corp-custom-solutions` GitHub org.

**5. Shopify Partner Portal access**
ThemeMate pulls themes via the Shopify CLI, which requires collaborator or staff access on the merchant store. Confirm you can log in to `partners.shopify.com` and see the merchant store under Stores.

**6. Chrome with remote debugging (for browser validation)**
ThemeMate validates features by connecting to your existing authenticated Chrome window. Before starting a session, launch Chrome with the remote debugging port open:
```bash
open -a "Google Chrome" --args --remote-debugging-port=9222
```
If Chrome is already running without this flag, quit it and relaunch with the command above.

This is a one-time setup per machine. Without it, ThemeMate falls back to asking you to confirm the preview manually in your browser.

---

### Setup

**1. Clone this repo**
```bash
git clone https://github.com/swym-corp-custom-solutions/claude-skills.git
cd claude-skills
```

**2. Run the installer for your OS**

**macOS / Linux**
```bash
bash install.sh
```

**Windows — PowerShell (native)**
```powershell
.\install.ps1
```
> If you see a script execution policy error, run:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

**Windows — Git Bash or WSL**
```bash
bash install.sh
```

The installer does three things in one step:
- Copies all skills from `./skills/` into `~/.claude/skills/`
- Installs the auto-updater script to `~/.claude/`
- Adds a Claude Code hook that auto-updates skills once per day

**3. Verify**
Start Claude Code and type `/thememate` — if the skill is installed correctly, Claude activates as ThemeMate.

---

### Updating

#### Auto-update (recommended)

Once installed, skills update themselves automatically. On the first prompt of each Claude Code session (once per calendar day), the updater checks `main` on GitHub. If any skill has a newer version, it is downloaded and the local copy is overwritten. You will see a one-liner confirmation when an update is applied:

```
[skill-updater] updated swym-shopify-thememate-theme-editor 2.0.0 -> 3.0.0
```

To force an immediate check (e.g. right after a PR merges to `main`):

**macOS / Linux / Git Bash**
```bash
rm /tmp/swym-skill-check-$(date +%Y%m%d).lock
bash ~/.claude/skill-updater.sh
```
**Windows (PowerShell)**
```powershell
Remove-Item "$env:TEMP\swym-skill-check-$(Get-Date -Format 'yyyyMMdd').lock" -ErrorAction SilentlyContinue
powershell -File "$HOME\.claude\skill-updater.ps1"
```

#### Manual update

If you prefer not to use the auto-updater, or need to update immediately:
```bash
cd claude-skills
git pull origin main
cp skills/swym-shopify-thememate-theme-editor/SKILL.md \
   ~/.claude/skills/swym-shopify-thememate-theme-editor/SKILL.md
```

To check what version is installed locally:
```bash
grep "version:" ~/.claude/skills/swym-shopify-thememate-theme-editor/SKILL.md
```

#### Rollback to a previous version

Each auto-update archives the replaced version locally at:
```
~/.claude/skills/<skill-name>/versions/SKILL-X.Y.Z.md
```

To roll back:
```bash
# List available local backups
ls ~/.claude/skills/swym-shopify-thememate-theme-editor/versions/

# Restore a specific version
cp ~/.claude/skills/swym-shopify-thememate-theme-editor/versions/SKILL-1.0.0.md \
   ~/.claude/skills/swym-shopify-thememate-theme-editor/SKILL.md
```

Named version snapshots are also committed to this repo under `skills/<name>/versions/` — see [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

---

### How to Use

**1. Start Claude Code from the project root**

ThemeMate expects to be run from the `swym-custom-solutions/` project root (or equivalent), not from inside a merchant subfolder. All CLI commands use relative paths like `./<merchant-slug>/`.

```bash
cd ~/Documents/2026/acq-request/swym-custom-solutions
claude
```

**2. Activate ThemeMate**
```
/thememate
```

**3. Describe the request**

ThemeMate picks up from there. Examples:
- "ACQ request — implement wishlisting on collection cards for merchantstore1.com"
- "The wishlist heart icon on the PDP needs to match the brand pink color for merchantstore2.com"
- "Audit what Swym features are active on merchantstore3.com"

ThemeMate identifies your role (ACQ, agency, merchant), detects whether a GitHub repo exists for the merchant, and selects the right workflow automatically.

---

### Updating

When the skill is updated in this repo, re-copy it to your local machine:

```bash
cd claude-skills
git pull origin main
cp -r skills/swym-shopify-thememate-theme-editor ~/.claude/skills/
```

To check which version you have locally, look at the `metadata.version` field in your installed `~/.claude/skills/swym-shopify-thememate-theme-editor/SKILL.md` and compare it to the same field in this repo.

---

### Contributing

Changes to ThemeMate affect all team members. Follow this process:

1. Branch off `main`: `git checkout -b update/<short-description>`
2. Edit `skills/swym-shopify-thememate-theme-editor/SKILL.md`
3. **Test in a live session** before opening a PR: copy the edited file to your `~/.claude/skills/` and run a real ThemeMate session on a sandbox merchant to verify the behavior change works as intended
4. **Archive the current version** -- copy the current `SKILL.md` into `versions/` under its current version number **before** bumping it:
   ```bash
   # e.g. if the current version is 2.0.0 and you are shipping 3.0.0:
   cp skills/swym-shopify-thememate-theme-editor/SKILL.md \
      skills/swym-shopify-thememate-theme-editor/versions/SKILL-2.0.0.md
   ```
   The `versions/` folder holds **superseded** versions only -- the current version is never archived there until it is replaced.
5. Update `metadata.version` and `metadata.last_updated` in the frontmatter
6. Add an entry to [CHANGELOG.md](CHANGELOG.md) -- mark the old entry as "Superseded by X.Y.Z" and add a new section for the new version
7. Open a PR — include in the body: what behavior changed, why, and which session or merchant surfaced the need

Do not merge a skill change that has not been tested in an active ThemeMate session.
