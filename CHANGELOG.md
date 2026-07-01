# Changelog

All notable changes to Swym Claude Skills are documented here.

Superseded versions are archived at `skills/<skill-name>/versions/SKILL-X.Y.Z.md`.
The archive is written **when a version is replaced**, not when it ships -- so the current
version is never in `versions/`. To roll back:
```bash
cp skills/swym-thememate/versions/SKILL-X.Y.Z.md \
   ~/.claude/skills/swym-thememate/SKILL.md
```

---

## Infrastructure

### [install] 2026-07-01 — Skill installer and auto-updater

**`install.sh`**
- One-command setup: copies skills to `~/.claude/skills/`, installs `skill-updater.sh`, wires Claude Code `UserPromptSubmit` hook in `~/.claude/settings.json`

**`skill-updater.sh`**
- Daily version check against GitHub `main` branch
- Auto-installs missing skills and auto-updates outdated ones
- Archives previous version to `~/.claude/skills/<name>/versions/SKILL-X.Y.Z.md` before overwriting for local rollback

---

## ThemeMate

### [2.0.0] 2026-07-01 — Multi-platform, API catalogue, role system overhaul

Current version. Archive will be created at `versions/SKILL-2.0.0.md` when the next version ships.

**Multi-platform scope**
- BigCommerce promoted from KNOWLEDGE-only to full THEME_EDIT: uses JS API + HANDOFF with Script Manager paste instructions
- Headless storefront support via REST API catalogue
- Skill description and intro updated to reflect Shopify, BigCommerce, and headless as supported platforms
- Shopify CLI scoped to Shopify storefronts only; standard file tools used for BigCommerce and headless

**IMPLEMENTATION_TYPE function (new)**
- Inserted before PLAN on every custom implementation session for `swym_acq`
- Classifies session as `storefront` (JS API) or `headless` (REST API); choice is locked for the full session
- Prevents mixing JS API and REST API in a single session

**SWYM API Catalogue (new, Section 9)**
- Authoritative list -- no `swat.*` method or REST endpoint outside this catalogue may be used
- JS API: 15 `swat.*` methods with full signatures; product object with platform-neutral `epi`/`empi` field comments for Shopify and BigCommerce
- REST API: confirmed endpoint paths from `developers.getswym.com/reference` with `path TBD` markers for unverified routes
- `swat.api.*` namespace explicitly prohibited (Swym internal only)
- Pricing/availability guidance made platform-conditional: Shopify Storefront API for Shopify; BigCommerce REST API or Stencil context for BigCommerce

**Role system**
- `swym_staff` added as a transient role: blocks all task execution until Swym team (ACQ/Success/Support) is confirmed
- `userEmail` guard added to role identification: `@swymcorp.com` check skipped when `userEmail` is absent from session context
- `swym_acq` profile updated: default Path B, IMPLEMENTATION_TYPE required before PLAN

**Tool use discipline**
- Restored removed guardrails: sequential edits to the same file, Edit vs Write rule
- Swym init wait snippet: fixed timer leak -- `setInterval` and `setTimeout` both cleared on resolve or timeout

**Swym docs reference**
- `mcp__swym-dev-docs__*` wildcard replaced with runtime-discoverable reference via ToolSearch against `developers.getswym.com/mcp`
- Web search fallback when MCP tools are unavailable

---

### [1.0.0] 2026-06-26 — Initial release

Superseded by 2.0.0. Archived at: `skills/swym-thememate/versions/SKILL-1.0.0.md`

**Workflow**
- Local-first workflow: pull theme, implement on feature branch, test with `shopify theme dev`, open PR
- Merchant store copy theme and GitHub connection are human-only post-merge steps; ThemeMate never pushes to merchant store during development

**Browser validation**
- DOM eval-first validation: `browser_evaluate` for functional checks, `browser_snapshot` for structural checks, screenshots only for brand discovery and visual issues
- Screenshot discipline: save to session scratchpad, delete after analysis, never leave in project or git-tracked paths

**Swym Control Center support**
- Inject wishlist-page JS in `layout/theme.liquid` with `page.handle contains 'wishlist'` guard
- Use `SwymCallbacks` array for post-initialization JS
- Use `e.isTrusted` to distinguish programmatic clicks from user clicks

**EXPLORE phase**
- Active template verification: check for both `.json` and `.liquid` variants; `.json` takes priority
- DOM presence check to confirm which template is actually rendering

**CDP browser setup**
- One-time Chrome remote debugging setup in BROWSER WINDOW SETUP section
- Playwright connects to existing authenticated window instead of opening incognito
