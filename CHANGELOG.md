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

### [install] 2026-08-05 — Auto-update telemetry-emit.sh and skill-updater.sh itself

`skill-updater.sh`'s daily check only ever re-pulled `SKILL.md` files -- `skill-updater.sh` and `telemetry-emit.sh` were installed once by `install.sh` and never touched again, so schema/PII changes to those two files (e.g. the `exit_summary`->`summary` rename below) silently never reached an existing install without a manual re-run of `install.sh`.

**`skill-updater.sh`**
- New `sync_file_from_repo()` helper: content-diff sync (not version-string comparison, since neither file is version-tagged like `SKILL.md`) -- fetches the remote file, `mv`s it over the local copy if different, restores the executable bit
- Deliberately **not** gated on SKILL.md's version -- infra-only fixes to these two files don't always ship with a skill version bump (this self-update mechanism itself is an example), so tying it to that would silently reopen the same gap for any future infra-only change
- To avoid paying for a full content fetch every day regardless of whether anything changed, a new `sync_if_sha_changed()` wraps `sync_file_from_repo()` behind a single lightweight `gh api repos/.../contents?ref=main` call that returns both files' current git blob SHA; a locally cached SHA (`~/.claude/.thememate-sync-shas`) means the full fetch only happens on a day the SHA actually differs
- `telemetry-emit.sh` now synced the same run as the `SKILL.md` check, gated on the existing `.thememate-telemetry-optout` marker (a bare `rm` of the file without that marker was always documented as a "this one install only" opt-out, not permanent -- see `install.sh`)
- The script now also self-updates at the very end of its own run. Safe despite overwriting the file it's currently executing: `mv` is a rename, and the already-running process keeps reading its already-open file descriptor's original inode content regardless of the rename (standard POSIX-rename self-update pattern, not something specific to this script)
- Verified the SHA-cache logic with a stubbed test harness: fetch+update on a new SHA, skip the fetch entirely when the cached SHA matches, fetch again once the SHA changes

### [telemetry-automation] 2026-08-05 — Rename exit_summary to summary, add feature/usecase/vertical/usecase_met

**`telemetry/schema.json`**
- `exit_summary` renamed to `summary` in `accepted_keys`/`column_order`
- New free-text keys: `feature`, `usecase`, `vertical` (no enum)
- New enum key: `usecase_met` (`yes`/`no`)
- `column_order` regrouped: `feature`/`usecase` next to `mode` (all resolved at `session_start`), `usecase_met` next to `outcome` (both session-end judgments), `vertical` next to `store_domain` (both store-context, resolved once BRAND_DISCOVER runs)

**`scripts/generate_telemetry_artifacts.py`** / **`telemetry/apps-script/Code.gs`** (generated) / **`telemetry-emit.sh`**
- The free-text PII regex condition (hardcoded in both the `Code.gs` template and `telemetry-emit.sh`'s `FREE_TEXT_KEYS` tuple) drops `exit_summary`, adds `summary` and `usecase`
- Migration note: the `exit_summary` header cell in the live Sheet needs a manual one-time rename to `summary` before redeploying, so existing data isn't split into two columns (`ensureHeaders_` only appends missing headers, it doesn't rename them)

### [telemetry-automation] 2026-08-05 — Upsert the heartbeat sheet by install_id

**`scripts/generate_telemetry_artifacts.py`** / **`telemetry/apps-script/Code.gs`** (generated)
- `HEARTBEAT_COLUMNS` changes shape from a raw per-event slice (`received_at, ts, install_id, skill, skill_version, ...heartbeat_keys`) to a derived per-install summary: `install_id, first_seen, last_seen, initial_version, current_version, ping_count, ...heartbeat_keys`
- `doPost`'s heartbeat branch now calls new `upsertHeartbeatRow_` instead of `appendRow_`: no existing row for an `install_id` -> insert with `first_seen = last_seen`, `initial_version = current_version`, `ping_count = 1`; existing row -> `last_seen`/`current_version` advance, `first_seen`/`initial_version` stay write-once, `ping_count` increments, `heartbeat_keys` fields use latest-non-blank-wins (same semantics `upsertRow_` already used for `events`)
- `findRowBySessionId_` generalized to `findRowByValue_(sheet, col, value)` so both `upsertRow_` (keyed on `session_id`) and `upsertHeartbeatRow_` (keyed on `install_id`) share the same row-lookup helper instead of duplicating it
- `skill-updater.sh`'s daily lock already guarantees at most one heartbeat per install per calendar day, so `ping_count` doubles as a distinct-days-active count without needing to retain the old per-day rows
- Verified with a standalone Node simulation of the merge logic: write-once fields (`first_seen`/`initial_version`) hold across repeated pings, advancing fields (`last_seen`/`current_version`) update, `ping_count` increments, and independent `install_id`s don't collide
- Migration note: an existing `heartbeat` tab written before this shipped is in the old per-event shape and won't fit the new columns -- rename/archive it before redeploying so `getOrCreateSheet_` creates a fresh tab (see `telemetry/README.md`)

**`telemetry/apps-script/InstallRollup.gs`**
- `processHeartbeatRollup_` now reads each install's single pre-aggregated heartbeat row directly (`first_seen`/`last_seen`/`initial_version`/`current_version`/`ping_count`) instead of scanning many historical per-day rows; `days_active` now comes from `ping_count`
- `processRollupSheet_` renamed to `processEventsRollup_`, scoped to `events` only; the `activeDays` day-counting `Set` (used by both sheets previously) is dropped in favor of `ping_count`

### [telemetry-automation] 2026-08-05 — Per-install rollup sheet, account_name field, heartbeat identity enrichment

**`telemetry/schema.json`**
- New `account_name` key in `accepted_keys`/`column_order` (free text, no enum -- same PII treatment as `feedback_note`/`exit_summary`)
- New `heartbeat_keys` array (`email_domain`, `account_name`) -- the subset of session-oriented fields the daily heartbeat ping is also allowed to carry, keeping `HEARTBEAT_COLUMNS` schema-driven instead of hand-edited

**`scripts/generate_telemetry_artifacts.py`** / **`telemetry/apps-script/Code.gs`** (generated)
- `load_schema()` validates every `heartbeat_keys` entry is also in `accepted_keys`
- `HEARTBEAT_COLUMNS` built from `heartbeat_keys` instead of a hardcoded list
- Free-text PII regex backstop (drop on email-shaped or long-digit-run content) extended to cover `account_name`

**`telemetry-emit.sh`**
- `account_name` added to the hand-maintained `FREE_TEXT_KEYS` tuple (same client-side PII scrub as `feedback_note`/`exit_summary`)

**`skill-updater.sh`**
- The daily heartbeat call now also resolves `email_domain` (`gh api user` / `git config user.email`, domain-only) and `account_name` (from the local one-time-answer cache) and passes both to `telemetry-emit.sh heartbeat` -- no LLM involved, best-effort, so idle installs that never open a real ThemeMate session still carry an identity signal

**`telemetry/apps-script/InstallRollup.gs`** (new, hand-maintained -- not touched by the generator)
- `buildInstallRollup()` reads `events` and `heartbeat` and writes one row per `install_id` to a new `install_rollup` sheet: `first_seen`, `last_seen`, `initial_version`, `current_version`, `account_name`, `email_domain`, `git_org`, `role`, `platform`, `session_count`, `days_active`, outcome counts, `success_rate`, `error_rate`, `avg_turns`, `avg_session_duration_min`, `satisfaction_*`
- Full overwrite on every run; exposed via a "Telemetry -> Rebuild Install Rollup" menu (`onOpen()`) and can be wired to a daily time-driven trigger

### [telemetry-automation] 2026-07-27 — Sync failure_category enum, avoid full-column scans

**`telemetry/schema.json`**
- `failure_category` enum was missing four values SKILL.md already instructs ThemeMate to emit (`sfl_cart_toggle_disabled`, `bis_stale_variant_binding`, `bis_custom_webhook_unreachable`, `unsupported_feature_requested`) -- `telemetry-emit.sh`'s enum check was silently dropping them from outgoing events. Added to bring schema.json back in sync with the documented contract.

**`scripts/generate_telemetry_artifacts.py`** / **`telemetry/apps-script/Code.gs`** (generated)
- `findRowBySessionId_` no longer pulls the entire `session_id` column into the script runtime via `getValues()` -- uses `Range.createTextFinder(...).matchEntireCell(true).findAll()` instead, keeping the scan server-side as the sheet grows

### [telemetry-automation] 2026-07-25 — Route the daily heartbeat ping to its own sheet

**`scripts/generate_telemetry_artifacts.py`** / **`telemetry/apps-script/Code.gs`** (generated)
- The daily `heartbeat` event (`skill-updater.sh`, no `session_id`, no session fields) now writes to a separate `heartbeat` sheet/tab with a fixed minimal column set (`received_at`, `ts`, `install_id`, `skill`, `skill_version`), instead of appending mostly-blank rows into `events` alongside real session data
- `getOrCreateSheet_` now takes a sheet name parameter instead of always opening `events`
- Verified with the mock-Sheet harness: `heartbeat` events land in their own sheet with only the minimal columns populated; session events still upsert into `events` as before

### [telemetry-automation] 2026-07-25 — One row per session_id (upsert) instead of one row per event

**`scripts/generate_telemetry_artifacts.py`** / **`telemetry/apps-script/Code.gs`** (generated)
- `doPost` now calls new `upsertRow_` instead of always `appendRow_`: if the incoming event's `session_id` already has a row in the sheet, its fields are merged onto that row in place (`event`/`received_at`/`ts` reflect the latest event; every other column keeps its prior value unless this event's payload also sets it) -- `session_start` -> `session_heartbeat` -> `session_end` for one session now collapse into a single row instead of three
- Events with no `session_id` (e.g. the `heartbeat` event `skill-updater.sh` sends daily, or a malformed/missing session_id that the emit script itself normally drops before it reaches here) still always append a new row -- there's nothing to key an upsert on
- New helper `findRowBySessionId_` scans the `session_id` column for the most recent matching row
- Verified with a local mock-Sheet harness: 3 events sharing one `session_id` collapsed to 1 row with fields merged as expected; a second, different `session_id` correctly stayed on its own row

### [telemetry-automation] 2026-07-25 — Fix column misalignment when new schema columns insert mid-list

**`scripts/generate_telemetry_artifacts.py`** / **`telemetry/apps-script/Code.gs`** (generated)
- Bug: `ensureHeaders_` appends any new column to the physical end of row 1, but `doPost` was writing each row's values by walking the canonical `TELEMETRY_COLUMNS` order from `schema.json` instead of the sheet's actual header order. Adding a new key anywhere but the very end of `column_order` (as done when `turns`/`session_duration_min`/`exit_summary` were added) silently shifted every value from that column onward into the wrong header for every row written since
- Fix: `ensureHeaders_` now returns the sheet's true physical header order (existing headers + any newly appended ones), and `doPost` passes that into `appendRow_` instead of the canonical schema list -- values are now written by actual header name/position, matching what the code was already documented (but not actually implemented) to do
- Existing rows written before this fix remain misaligned in the Sheet; only rows written after redeploying this fix are correct

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

### [2.10.0] 2026-08-05: usecase/summary/usecase_met, feature and vertical in telemetry

Current version.

**Section 14 -- TELEMETRY**
- `exit_summary` renamed to `summary`. Previously only sent optionally at `session_heartbeat`/`session_end`; now always seeded at `session_start` too, refined at `session_heartbeat`, finalized at `session_end`. Existing `heartbeat`/`events` sheets need the `exit_summary` header cell manually renamed to `summary` so history and new data land in the same column (see `telemetry/README.md`).
- New `usecase` field: one-line description of what the user came to do, written once at `session_start`, stable for the session -- distinct from `summary`, which is the evolving *what's happening now* rather than the stable *why*.
- New `usecase_met` field (`yes`/`no`): ThemeMate's own judgment at `session_end` of whether what happened actually satisfies `usecase` -- distinct from `outcome` (session completion state) and `satisfaction` (the user's own after-the-fact rating). Self-assessed, not asked to the user.
- New `feature` field in telemetry: wires the already-resolved `{feature}` (Section 3, FEATURE identification) into `session_start` -- no new inference, just passes through a value the skill already computes for every session.
- New `vertical` field in telemetry: wires the already-recorded `{vertical}` (BRAND_DISCOVER Step 8, Section 5 -- already used for METADATA.md) into `session_end` whenever `store_domain` is included -- no new inference here either.
- `usecase` added to the free-text PII backstop (same treatment as `feedback_note`/`summary`) since it's LLM-paraphrased from the user's own request. `feature`/`vertical` are short AI-classified labels, not verbatim user text -- excluded from that list.

### [2.9.0] 2026-08-05: Role/account_name caching, email_domain for every mode

Superseded by 2.10.0. Archived at `versions/SKILL-2.9.0.md`.

**Section 2 -- ROLES**
- The "which Swym team" ask (rule 2, now rule 3) and the "Swym/agency/merchant" fallback ask (rule 5, now rule 6) previously fired every session with no memory of a prior answer. Both now cache their resolved value to `~/.claude/.thememate-role`, checked before either ask runs -- a returning user isn't asked again. An explicit in-session role statement (rule 1) always overwrites the cache. Context-inferred `agency`/`merchant` (rule 5, from "my client's store" vs "my store") is intentionally not cached -- that can legitimately vary session to session for the same person.

**Section 14 -- TELEMETRY**
- `email_domain` now resolves at `session_start` for every MODE (KNOWLEDGE, THEME_INSPECT, THEME_EDIT), not only THEME_EDIT sessions that reach `GITHUB_SETUP` -- same opportunistic `gh api user` / `git config user.email` lookup, just run unconditionally and earlier. `GITHUB_SETUP` still runs the same lookup as a fallback.
- New `account_name` field: a voluntary, self-disclosed name or agency label, asked once ever per install (gated on `~/.claude/.thememate-account-name` not existing, cached like `role` above), combined into a single message with the role ask when both fire in the same (first-ever) session. Always skippable. Gets the same free-text PII backstop as `feedback_note`/`exit_summary` (dropped if it looks like an email or long digit run). This is a deliberate exception to "never PII" -- it identifies the ThemeMate operator, never a merchant or customer.

### [2.8.0] 2026-07-24: Turns, session duration, and exit summary telemetry

Superseded by 2.9.0. Archived at `versions/SKILL-2.8.0.md`.

**Section 14 -- TELEMETRY**
- New running counters tracked from `session_start` onward: `turns` (running count of user messages) and `session_duration_min` (elapsed minutes since `session_start`, computed from `$(date +%s)`)
- New `session_heartbeat` event: fires every 5 user turns so a long-running or abandoned session still leaves partial data even when `session_end` never fires
- `session_end` now always includes `turns`/`session_duration_min`, and optionally `exit_summary` -- a short LLM-written one-line summary of what happened this session, sharing `feedback_note`'s PII backstop (the emit script drops the field if it looks like it contains an email or long digit run)

**`telemetry-emit.sh`**
- New allowed keys: `turns`, `session_duration_min`, `exit_summary`
- The existing `feedback_note` PII backstop (drop on email-shaped or long-digit-run content) now also applies to `exit_summary`

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
