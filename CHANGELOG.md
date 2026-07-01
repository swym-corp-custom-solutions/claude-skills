# Changelog

All notable changes to Swym Claude Skills are documented here.

Each version is archived at `skills/<skill-name>/versions/SKILL-X.Y.Z.md` for rollback.
To roll back to a specific version locally:
```bash
cp skills/swym-shopify-thememate-theme-editor/versions/SKILL-X.Y.Z.md \
   ~/.claude/skills/swym-shopify-thememate-theme-editor/SKILL.md
```

---

## Infrastructure

### [install] 2026-07-01 — Skill installer and auto-updater

**`install.sh`**
- One-command setup: copies skills to `~/.claude/skills/`, installs `skill-updater.sh`, wires Claude Code `UserPromptSubmit` hook

**`skill-updater.sh`**
- Daily version check against GitHub `main` branch
- Auto-installs missing skills, auto-updates outdated ones
- Archives previous version to `~/.claude/skills/<name>/versions/SKILL-X.Y.Z.md` before overwriting (local rollback without needing git)

---

## ThemeMate

### [2.0.0] 2026-07-01 — Multi-platform, API catalogue, role system overhaul

Archived at: `skills/swym-shopify-thememate-theme-editor/versions/SKILL-2.0.0.md`

**Multi-platform scope**
- BigCommerce promoted from KNOWLEDGE-only to full THEME_EDIT: uses JS API + HANDOFF with Script Manager paste instructions
- Headless storefront support via REST API catalogue
- Skill intro and YAML description updated to reflect Shopify, BigCommerce, and headless as supported platforms
- `IMPLEMENTATION_TYPE` function introduced: classifies storefront vs headless at session start, locks the API choice for the full session

**SWYM API Catalogue (new, Section 9)**
- Authoritative reference for all permitted API calls -- no method outside this list may be used
- JS API: 15 `swat.*` methods with full signatures, parameters, and the product object shape (`epi`, `empi`, `du` with Shopify and BigCommerce field equivalents)
- REST API: confirmed endpoint paths from `developers.getswym.com/reference`, with explicit `path TBD` markers for unverified routes
- `swat.api.*` explicitly prohibited (Swym internal namespace only)
- Pricing and availability guidance made platform-conditional: Shopify Storefront API for Shopify; BigCommerce REST API / Stencil context for BigCommerce

**Role system**
- `swym_staff` added as a transient role: blocks all task execution until team (ACQ/Success/Support) is confirmed
- `userEmail` guard added: `@swymcorp.com` check skipped entirely when `userEmail` is absent from session context
- Role identification rule numbering clarified with explicit guard (rule 0)

**Tool use discipline**
- Restored removed guardrails: sequential edits to the same file, Edit vs Write rule
- Swym init wait snippet: fixed timer leak -- both `setInterval` and `setTimeout` now cleaned up on resolve or timeout

**Swym docs reference**
- `mcp__swym-dev-docs__*` wildcard replaced with runtime-discoverable instruction via ToolSearch against `developers.getswym.com/mcp`
- Web search kept as fallback when MCP tools are unavailable

---

### [1.0.0] 2026-06-26 — Initial release

Archived at: `skills/swym-shopify-thememate-theme-editor/versions/SKILL-1.0.0.md`

**Workflow**
- Local-first workflow: pull theme, implement on feature branch, test with `shopify theme dev`, open PR
- Merchant store copy theme and GitHub connection are human-only post-merge steps; ThemeMate never pushes to merchant store during development

**Browser validation**
- DOM eval-first validation: `browser_evaluate` for functional checks, `browser_snapshot` for structural checks, screenshots only for brand discovery and visual issues that cannot be verified via DOM
- Screenshot discipline: save to session scratchpad, delete after analysis, never leave in project or git-tracked paths

**Swym Control Center support**
- Inject wishlist-page JS in `layout/theme.liquid` with `page.handle contains 'wishlist'` guard, not in page template files
- Use `SwymCallbacks` array for post-initialization JS
- Use `e.isTrusted` to distinguish programmatic clicks from user clicks

**EXPLORE phase**
- Active template verification: check for both `.json` and `.liquid` variants; `.json` takes priority
- DOM presence check to confirm which template is actually rendering

**CDP browser setup**
- One-time Chrome remote debugging setup in BROWSER WINDOW SETUP section
- Playwright connects to existing authenticated window instead of opening incognito
