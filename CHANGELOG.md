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

### [telemetry-automation] 2026-07-24 — Schema-driven telemetry + Apps Script column migration

**`telemetry/schema.json`** (new)
- Single source of truth for telemetry accepted keys, enum constraints, and Google Sheet column order

**`scripts/generate_telemetry_artifacts.py`** (new)
- Generates schema blocks in `telemetry-emit.sh`
- Generates `telemetry/apps-script/Code.gs` receiver from schema
- Supports `--check` mode for CI drift detection

**`telemetry/apps-script/Code.gs`** (new, generated)
- Validates token (when script property `THEMEMATE_TOKEN` is set)
- Auto-migrates missing header columns in row 1 on ingest
- Appends rows by schema header mapping rather than fixed column index

**CI**
- Added `.github/workflows/telemetry-schema-check.yml` to enforce generated artifacts are up to date in PRs and on `main`

### [install] 2026-07-01 — Skill installer and auto-updater

**`install.sh`**
- One-command setup: copies skills to `~/.claude/skills/`, installs `skill-updater.sh`, wires Claude Code `UserPromptSubmit` hook in `~/.claude/settings.json`

**`skill-updater.sh`**
- Daily version check against GitHub `main` branch
- Auto-installs missing skills and auto-updates outdated ones

### [telemetry] 2026-07-02 — ThemeMate usage telemetry

**`telemetry-emit.sh`** (new)
- Anonymous, best-effort event emitter installed to `~/.claude/telemetry-emit.sh`
- Two signal types: a deterministic daily `heartbeat` (fired from `skill-updater.sh`, works even without `gh` CLI) and rich `session_start`/`session_end` events self-reported by ThemeMate mid-session
- Posts JSON to a Google Sheets Apps Script endpoint; never blocks, never retries, never errors loudly
- No customer PII in any event -- closed enums only for role/mode/platform/outcome/failure category
- Opt out by deleting `~/.claude/telemetry-emit.sh`

**`install.sh`**
- Installs `telemetry-emit.sh` alongside the skill updater

**`skill-updater.sh`**
- Emits the `heartbeat` event once per calendar day, gated by its own lockfile so it still fires on machines with no `gh` CLI (e.g. merchants)

---

## ThemeMate

### [2.3.0] 2026-07-07: Defer GitHub repo/PR creation until after preview confirmation

Current version. Archive will be created at `versions/SKILL-2.3.0.md` when the next version ships.

**Section 5 -- GITHUB_SETUP split into LOCAL_GIT_INIT + GITHUB_SETUP + new PUBLISH_CHOICE**
- Previously `GITHUB_SETUP` ran before `EDIT`, creating a real GitHub repo and pushing a baseline commit before the user had seen any change or confirmed they wanted a repo at all
- New `LOCAL_GIT_INIT` (before `EDIT`): purely local -- `git init`, baseline commit, `feature/<slug>` branch. No `gh` calls, no confirmation needed, nothing leaves the machine. Prerequisite for EDIT's per-change commits and TEST's rollback tiers
- `GITHUB_SETUP` trimmed to the GitHub-facing half only -- org/repo resolution, confirmation, `gh repo create` (new repo only), remote add, push of the baseline already committed by `LOCAL_GIT_INIT`. No longer runs unconditionally pre-EDIT
- New `PUBLISH_CHOICE` (after TEST's existing confirmation gate): asks whether to push to GitHub + open a PR, or receive a HANDOFF package instead. Falls back to HANDOFF automatically if the user has no GitHub org/repo-create access, instead of dead-ending
- `TEST`'s confirmation gate now blocks progression to `PUBLISH_CHOICE` (previously blocked `PR_FLOW` directly)
- Sequence tables (Section 4) and the THEME_EDIT flow diagram (Section 3) updated to reflect `... -> LOCAL_GIT_INIT -> EDIT -> TEST -> PUBLISH_CHOICE -> [GITHUB_SETUP -> PR_FLOW | HANDOFF]`
- `merchant` role and the `DEMO_PUSH` (no-access) path are unaffected -- neither ever touched `GITHUB_SETUP`

### [2.2.0] 2026-07-03: Store/agency identifiers, lines-written, and session feedback telemetry

Superseded by 2.3.0. Archived at `versions/SKILL-2.2.0.md`.

**Section 14 -- TELEMETRY**
- `session_end` now includes, whenever resolved that session: `store_domain` (was already accepted by `telemetry-emit.sh` but never actually sent by `SKILL.md`), `lines_written` (THEME_EDIT only), `git_org`/`git_repo`, `pr_url`, and `preview_url`
- `git_org` doubles as the agency identifier for `role=agency` sessions -- no separate agency-name field
- New `feedback` event: closed-enum `satisfaction` (positive/neutral/negative) asked at the session-ending point, or fired immediately if the user reports a delivered fix didn't work; `satisfaction=negative` also collects a closed-enum `feedback_reason` and an optional one-line `feedback_note`
- ThemeMate must warn the user before asking for `feedback_note` that it's shared with Swym and must not include personal details
- Never asks for a merchant's or user's email address -- `email_domain` is read opportunistically from already-configured `gh`/`git` identity, and only the domain half is ever kept

**Section 5 -- EDIT, GITHUB_SETUP, PR_FLOW, DEMO_PUSH**
- EDIT Step C: tally `{lines_written}` as a running count of lines actually written via Write/Edit calls, not an estimate
- GITHUB_SETUP: resolve `{email_domain}` from `gh api user`/`git config user.email` (optional, best-effort, never asked for) -- strip and discard the local part before it leaves this step, extra org/agency visibility signal for sessions where `git_org` doesn't resolve
- PR_FLOW: hold the `gh pr create` URL as `{pr_url}` for the same `session_end` call
- DEMO_PUSH Step 4: hold the constructed demo preview URL as `{preview_url}` for whichever `session_end` call this session reaches

**`telemetry-emit.sh`**
- New allowed keys: `lines_written`, `satisfaction`, `feedback_reason`, `feedback_note`, `git_org`, `git_repo`, `pr_url`, `preview_url`, `email_domain`
- `feedback_note` is free text -- the script drops it entirely if it matches an email pattern or a long digit run (phone/order-number shaped), as a backstop behind the in-skill warning
- `email_domain` is rejected outright (field dropped, not truncated) if it contains `@` or isn't shaped like a bare domain -- a hard backstop behind the in-skill strip-and-discard step

### [2.1.1] 2026-07-02: Fix broken CDP browser setup instructions

Archived at `versions/SKILL-2.1.1.md`.

**Section 6 -- BROWSER SETUP (rewritten)**
- `open -a "Google Chrome" --args ...` silently dropped the debug flag whenever Chrome was already running, so the debug port never opened
- Chrome also hard-blocks remote debugging on the user's default profile directory, so a dedicated automation profile at `~/.claude/thememate-chrome-profile` is created once and launched via the Chrome binary directly, verified with `curl` before Playwright connects
- Login to that profile is one-time and only needed for Partner Portal/admin tasks; public storefront pages need no login
- Launch/cleanup commands match on the dedicated profile dir (not just the port flag) so an unrelated process on port 9222 is never mistaken for the automation instance
- Verified against a live store

### [2.1.0] 2026-07-02: Usage telemetry instrumentation

Superseded by 2.1.1. Archived at `versions/SKILL-2.1.0.md`.

**Section 14 -- TELEMETRY (new)**
- `session_start` fired after MODE classification; `session_end` fired at DIAGNOSTIC_SUMMARY, PR_FLOW (after `gh pr create`), or HANDOFF package delivery
- Closed enums for role/mode/platform/outcome/failure_category/escalated_to -- `failure_category` maps 1:1 to Section 8's eight COMMON FAILURE PATTERNS
- A `session_start` with no matching `session_end` is read downstream as an abandoned session -- ThemeMate never self-reports abandonment
- See `telemetry-emit.sh` in Infrastructure above for the transport

### [2.0.0] 2026-07-01 — Multi-platform, API catalogue, role system overhaul

Superseded by 2.1.0. Archived at `versions/SKILL-2.0.0.md`.

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
