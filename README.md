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
```

**2. Create the skills directory if it does not exist**
```bash
mkdir -p ~/.claude/skills
```

**3. Copy the skill**
```bash
cp -r claude-skills/skills/swym-shopify-thememate-theme-editor ~/.claude/skills/
```

**4. Verify**
Start Claude Code and type `/thememate` — if the skill is installed correctly, Claude activates as ThemeMate.

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
4. Update `metadata.version` (increment patch for fixes, minor for new behavior) and `metadata.last_updated` in the frontmatter
5. Add an entry to [CHANGELOG.md](CHANGELOG.md)
6. Open a PR — include in the body: what behavior changed, why, and which session or merchant surfaced the need

Do not merge a skill change that has not been tested in an active ThemeMate session.
