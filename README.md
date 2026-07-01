# Swym Claude Skills

Claude Code skills for Swym staff (ACQ, Success, Support), agencies, and merchants. Each skill is a self-contained directory under `skills/` that gets installed into `~/.claude/skills/` on your local machine.

---

## Available Skills

| Skill | Invocation | Description |
|-------|-----------|-------------|
| [ThemeMate](skills/swym-thememate/) | `/thememate` | Implement and debug Swym Wishlist UI on Shopify, BigCommerce, and headless storefronts |

---

## ThemeMate

ThemeMate turns Claude Code into an expert theme assistant for Swym across Shopify, BigCommerce, and headless storefronts. You describe what needs to change and ThemeMate handles the full workflow: pulling the theme, exploring files, implementing the change, running local browser validation, and opening a PR for review.

**Platform routing:** Shopify uses the Shopify CLI. BigCommerce delivers code via Script Manager paste instructions. Headless uses the Swym REST API. ThemeMate picks the right path automatically based on the storefront type.

**Swym Developer Docs MCP** is used when available for API reference and code standards lookups. Falls back to web search if not connected.

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

**3. Shopify CLI** _(Shopify storefronts only)_
```bash
npm install -g @shopify/cli@latest
shopify auth login   # log in with your Shopify Partner account
```
Not required for BigCommerce or headless sessions.

**4. GitHub CLI** _(Swym staff and agencies only -- not required for merchants)_
```bash
gh auth login
```
Install via [cli.github.com](https://cli.github.com) if not already present (`brew install gh` on macOS, `winget install GitHub.cli` on Windows).
Swym staff need access to the `swym-corp-custom-solutions` org. Agencies use their own org (ThemeMate will prompt for it at session start).

**5. Shopify Partner Portal access** _(Shopify storefronts only)_
ThemeMate pulls themes via the Shopify CLI, which requires collaborator or staff access on the merchant store. Confirm you can log in to `partners.shopify.com` and see the merchant store under Stores. Not required for BigCommerce or headless sessions.

**6. Chrome with remote debugging (for browser validation)**
ThemeMate validates features by connecting to your existing authenticated Chrome window. Before starting a session, launch Chrome with the remote debugging port open:

```bash
# macOS
open -a "Google Chrome" --args --remote-debugging-port=9222

# Linux
google-chrome --remote-debugging-port=9222
```

> **Windows (Git Bash / WSL):** `start chrome --remote-debugging-port=9222`

If Chrome is already running without this flag, quit it and relaunch with the command above.

Without it, ThemeMate falls back to asking you to confirm the preview manually in your browser.

---

### Setup

**1. Clone this repo**
```bash
git clone https://github.com/swym-corp-custom-solutions/claude-skills.git
cd claude-skills
```

**2. Run the installer**
```bash
bash install.sh
```

> **Windows:** use Git Bash or WSL. Both ship with most Git for Windows installs — open "Git Bash" from the Start menu and run the command above.

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
[skill-updater] updated swym-thememate 2.0.0 -> 3.0.0
```

To force an immediate check (e.g. right after a PR merges to `main`):
```bash
rm /tmp/swym-skill-check-$(date +%Y%m%d).lock
bash ~/.claude/skill-updater.sh
```

#### Disable auto-update

To stop the daily hook from running, remove the `UserPromptSubmit` entry from `~/.claude/settings.json`:
```bash
# Open in your editor and remove the "UserPromptSubmit" block under "hooks"
open ~/.claude/settings.json
```

Or delete the updater script entirely:
```bash
rm ~/.claude/skill-updater.sh
```

The hook will silently no-op if the script is missing, so either approach is safe.

#### Manual update

If you prefer not to use the auto-updater, or need to update immediately:
```bash
cd claude-skills
git pull origin main
cp skills/swym-thememate/SKILL.md \
   ~/.claude/skills/swym-thememate/SKILL.md
```

To check what version is installed locally:
```bash
grep "version:" ~/.claude/skills/swym-thememate/SKILL.md
```

#### Rollback to a previous version

Previous versions are committed to this repo under `skills/<name>/versions/`. See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

```bash
cd claude-skills
git pull origin main

# Copy the version you want directly into your local skill folder
cp skills/swym-thememate/versions/SKILL-1.0.0.md \
   ~/.claude/skills/swym-thememate/SKILL.md
```

---

### Telemetry & Privacy

`install.sh` also installs `telemetry-emit.sh` to `~/.claude/telemetry-emit.sh`. ThemeMate uses it to report anonymous, best-effort usage events so Swym can see adoption and reliability trends and improve the skill where it's weakest.

**What's collected:** role, mode, storefront platform, session outcome, failure category, timing, skill version, and the store domain/slug. **Never customer PII, never merchant customer data.**

**How it's collected:** a daily heartbeat (from `skill-updater.sh`, works even without `gh` CLI) plus `session_start`/`session_end` events self-reported by ThemeMate at natural session-ending points (DIAGNOSTIC_SUMMARY, PR creation, HANDOFF). See Section 14 of `SKILL.md` for the full mechanism.

**Opt out:** delete `~/.claude/telemetry-emit.sh`. Both call sites treat a missing file as a silent no-op -- nothing else changes.

---

### How to Use

**1. Start Claude Code from your project root**

ThemeMate works from a project root directory where merchant theme folders live as subdirectories (e.g. `./<merchant-slug>/`). Run Claude from that root — not inside a merchant subfolder.

```bash
cd /path/to/your/project-root
claude
```

**2. Activate ThemeMate**
```
/thememate
```

**3. Describe the request**

ThemeMate asks about your role once (ACQ, Success, Support, agency, or merchant) and detects the storefront platform, then selects the right workflow automatically. You don't need to state your role upfront -- just describe what you need.

**ACQ (Advance Customisation Queue):**
- "Implement wishlisting on collection cards for merchantstore.com"
- "Replace the default Swym heart button with a custom Add to Wishlist CTA"
- "Build a headless wishlist using the REST API for this Next.js storefront"

**Success / onboarding:**
- "We're onboarding merchantstore.com -- audit what Swym features are active and what's missing"
- "Prepare a demo of wishlist on collection and PDP for a prospect pitch"

**Support / diagnostics:**
- "The wishlist button isn't appearing on the PDP for merchantstore.com -- help me debug"
- "Swym loads on desktop but breaks on mobile -- investigate"

**Agency:**
- "My client myclientstore.com needs wishlist buttons on their BigCommerce collection grid"
- "Implement a custom wishlist drawer for the client's Shopify theme"

**Merchant:**
- "Add a wishlist heart to product cards on my Shopify store"
- "The wishlist icon colour doesn't match my theme -- how do I change it?"

---

### Contributing

Changes to ThemeMate affect all team members. Follow this process:

1. Branch off `main`: `git checkout -b update/<short-description>`
2. Edit `skills/swym-thememate/SKILL.md`
3. **Test in a live session** before opening a PR: copy the edited file to your `~/.claude/skills/` and run a real ThemeMate session on a sandbox merchant to verify the behavior change works as intended
4. **Archive the current version** -- copy the current `SKILL.md` into `versions/` under its current version number **before** bumping it:
   ```bash
   # e.g. if the current version is 2.0.0 and you are shipping 3.0.0:
   cp skills/swym-thememate/SKILL.md \
      skills/swym-thememate/versions/SKILL-2.0.0.md
   ```
   The `versions/` folder holds **superseded** versions only -- the current version is never archived there until it is replaced.
5. Update `metadata.version` and `metadata.last_updated` in the frontmatter
6. Add an entry to [CHANGELOG.md](CHANGELOG.md) -- mark the old entry as "Superseded by X.Y.Z" and add a new section for the new version
7. Open a PR — include in the body: what behavior changed, why, and which session or merchant surfaced the need

Do not merge a skill change that has not been tested in an active ThemeMate session.
