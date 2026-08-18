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

### [telemetry-automation] 2026-08-05 — Code review fixes: falsy-0 handling, server-side email_domain check, SHA-cache correctness

Addresses Copilot review findings on PR #17.

**`telemetry/apps-script/InstallRollup.gs`**
- New shared `cellValue_()` replaces two duplicated `getVal` closures that used `row[col[name]] || ''` -- that coerced a legitimate falsy cell value (e.g. `turns=0`, `ping_count=0`) to an empty string, silently excluding it from averages/counts. Explicit undefined/null check instead.

**`scripts/generate_telemetry_artifacts.py`** / **`telemetry/apps-script/Code.gs`** (generated)
- `normalizePayload_` now validates `email_domain`'s shape server-side (mirrors `telemetry-emit.sh`'s `EMAIL_DOMAIN_PATTERN`) instead of relying solely on the client-side check -- `doPost` already documents that it can't trust a caller went through the emit script, so a direct POST to the web app could otherwise store a full email address in that column.

**`skill-updater.sh`**
- `sync_if_sha_changed`'s cache lookups switched from `grep "^$name="` to `awk -F= -v n="$name" '$1==n'` -- `$name` (e.g. `telemetry-emit.sh`) contains a literal `.`, a regex metacharacter grep would otherwise interpret as "any character," risking a false match against an unrelated cache line.
- `sync_file_from_repo` now returns non-zero on a failed fetch (empty response), and `sync_if_sha_changed` only writes the new SHA to the cache when the fetch actually succeeded -- previously a transient `gh api` failure on the day the SHA changed would still cache that SHA, making the real update look "already applied" and permanently skipping it.
- Verified with a stubbed test: a failed fetch leaves the cache untouched (retries next run); a successful fetch on the next attempt caches correctly.

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

### [2.17.0] 2026-08-18: Hard gate on PLAN confirmation, PREREQUISITES/role-priority fixes, Shopify-only platform gate for THEME_INSPECT/THEME_EDIT

Current version.

**Root cause:** THEME_EDIT's function sequence already routed every path through PLAN before EDIT, and PLAN said to "wait for user confirmation" -- but that phrasing was advisory prose, not a hard stop, so it read as a suggestion that could plausibly be skipped for "obviously small" asks. User feedback: theme edit sessions should never start implementing directly off the initial ask, even for small changes -- discovery/analysis produces a plan, the user gets to request changes to it, and only explicit confirmation of that plan opens the door to writing files.

**`skills/swym-thememate/SKILL.md`**
- Section 1 TOOLS: new explicit hard-gate rule under "Writing theme files" -- no Write, Edit, `rm`, or `shopify theme push` call may happen in THEME_EDIT until PLAN has been presented and the user has explicitly confirmed it; presenting the plan is not itself confirmation.
- PLAN function: replaced the soft "wait for user confirmation before starting EDIT" line with an explicit gate covering CSS-only/small changes too, and requiring a revised plan to be re-presented and re-confirmed if the user asks for changes.
- EDIT function: new entry check at the top of the function -- confirm the user explicitly confirmed the plan for this specific ask before doing anything else in EDIT; silence or the user simply continuing the conversation does not count.
- PREREQUISITES' "Called by" line was missing `merchant`, contradicting Section 4's own THEME_EDIT has-access sequence table (which lists PREREQUISITES for the merchant role). Added `merchant` to the Called-by line.
- PREREQUISITES Check 2 referenced "a Path B session" as if PLAN had already decided it, but PLAN runs after PREREQUISITES in every sequence. Reworded to reference the role's stated *default* (Section 2) or already-expressed user intent instead of an unresolved decision.
- PREREQUISITES, THEME_PULL, and AUDIT were written exclusively for Shopify (App Embed, `config/settings_data.json`, `shopify theme pull`) with no BigCommerce path, despite BigCommerce being listed as a supported THEME_EDIT platform in Section 13. Initially patched with a BigCommerce-specific instruction-mode path through those functions; superseded within this same version once product direction landed (see next item) on restricting THEME_INSPECT/THEME_EDIT to Shopify only for now -- that in-flow BigCommerce plumbing was removed as dead code rather than left unreachable.
- **Product decision: THEME_INSPECT and THEME_EDIT are Shopify-only for now.** BigCommerce, headless/custom frontends, and (already) WooCommerce/Wix are KNOWLEDGE-only until audit/edit support for them is built (roadmap item, not scheduled). New platform gate in Section 3 (MODE classification) resolves MODE to KNOWLEDGE for a named non-Shopify platform up front, with a matching backstop in BRAND_DISCOVER Step 1 (`window.Shopify?.shop` check) for when the platform wasn't known until the store was actually probed -- either path falls back to KNOWLEDGE with a plain "not available yet, on the roadmap" message and emits `session_end` (`outcome=blocked failure_category=out_of_scope`). Section 13's platform bullets, IMPLEMENTATION_TYPE's Called-by note, THEME_PULL's Called-by note, and AUDIT's Called-by note all updated to say Shopify-only; the JS/REST API catalogues (Section 9) and IMPLEMENTATION_TYPE's classification table are left in place as roadmap reference, not deleted.
- Role behaviors clarified for Path A (default config changes) vs Path B (custom implementation) precedence, which wasn't stated for `swym_support`/`agency` and was under-specified for `swym_acq`: `swym_support`'s primary approach is now explicitly Path A (custom solution secondary, only when config changes can't fix it); `swym_acq` and `agency` now explicitly default to Path B as primary even when the ask is achievable via default config, with config-change suggestions as the secondary option.
- Frontmatter `description` (the field that decides when this skill gets invoked at all) still advertised "implement Swym UI on a Shopify or BigCommerce storefront, or build headless integrations via the Swym REST API" -- directly contradicted the new platform gate above. Reworded to say audit/edit is Shopify-only for now and BigCommerce/headless are answered knowledge-only.
- PR review (Copilot): the platform gate's `failure_category=platform_not_supported` isn't in Section 14's closed enum -- the telemetry receiver would silently drop it. Changed to the existing `out_of_scope` value, which the enum's own usage note already earmarks for "other blocked/error paths described elsewhere in this skill."

### [2.16.0] 2026-08-11: account_name on every session, log-correlated session close, SKILL.md completeness

Superseded by 2.17.0. Archived at `versions/SKILL-2.16.0.md`.

**Root cause:** auditing 2.15.0's backstop against the actual production sheet and a sibling project (`avery-onboarding-suite`) found four problems that weren't "row missing" (2.15.0 already fixed that) but "row exists, wrong or incomplete." Each is a different failure mode, fixed independently.

**`telemetry-emit.sh` -- `account_name` now attaches to every event, not just a machine's first-ever session**
- Bug: SKILL.md gated both the one-time interactive ask AND the field's attachment behind the same `~/.claude/.thememate-account-name`-not-existing flag, on the theory that later sessions' rows would "carry it forward via the sheet's upsert-merge" -- but `upsertRow_` merges by exact `session_id`, and every session gets a new one (new row), so nothing ever carried across. Only the very first-ever session on a machine ever showed a name.
- Fix: `telemetry-emit.sh` now reads the cache file and auto-attaches `account_name` to every outgoing event itself, mirroring how `install_id` already works -- no caller (SKILL.md's own emits, `thememate-autolog.py`'s synthetic backstop emits, `skill-updater.sh`'s heartbeat) has to do anything. SKILL.md keeps the one-time interactive ask (only a chat turn can do that) but no longer threads `account_name=` through its sample `session_start` command.

**`telemetry-emit.sh` -- local audit-log rotation race fixed (`flock` via `fcntl`, not the CLI tool, which isn't on macOS by default)**
- The append-then-rotate-to-500-lines sequence for `~/.claude/.thememate-telemetry.log` was an unlocked read-modify-write; two ThemeMate sessions emitting close together could lose one's line. Harmless while the log was purely a debug trail -- now load-bearing (see next item), so it's locked.

**`thememate-autolog.py` -- session-close identity resolution now correlates against the local telemetry log instead of extracting a literal UUID from transcript text**
- Confirmed live: the LLM sometimes generates `session_id` into a shell variable (`SESSION_ID=$(...)`, `session_id=$SESSION_ID`) rather than a literal value -- no static transcript-text scan can ever resolve that, so an orphaned `session_start` with no `session_end` previously fell through to "do nothing client-side," relying entirely on the 24h sweep.
- Fix: `telemetry-emit.sh` already logs bash's *already-resolved* argv to its local audit log, so the log always has the real literal id regardless of how the LLM constructed it. `SessionEnd` now correlates this session's own `session_start` Bash-call transcript timestamp against that log within a 45-second window to recover the real id -- safe by construction (too-tight a match just falls through to the sweep below, never wrongly closes a still-running session; a global cross-terminal sweep by short time-since-last-line was considered and rejected for the opposite reason: `session_heartbeat`'s cadence is turn-count-based, not wall-clock, so a real in-progress session can easily go quiet longer than any short buffer). State shape simplified: dropped the `started`/`ended` literal-uuid lists entirely, added `session_start_ts`.

**`telemetry/apps-script/InstallRollup.gs` -- `reconcileStaleSessions` tightened from daily/24h to hourly/4h**
- `received_at` refreshes on every event for a session (including heartbeats), so a legitimately active session never goes stale regardless of how tight this runs -- only a truly hard-killed one (the case no client-side hook can catch at all) does. Closes that case in about an hour instead of up to a day.

**`skills/swym-thememate/SKILL.md` -- three missing localized session-ending reminders added**
- `AUDIT`'s session-ending reminder previously only covered the `swym_support`/`DIAGNOSTIC_SUMMARY` sub-case; a plain THEME_INSPECT completion for the other four roles had none. `DEMO_PUSH` Step 6 only covered "user says yes to HANDOFF"; the decline branch had none. The `agency`/`merchant` block endpoints in Section 4's function-sequence table resolve into prose, not a named function, so they never had anywhere to hang a reminder -- added an inline note directly after the table instead. None of these were "row missing" (2.15.0's backstop already guaranteed a row) but each produced a sparse, backstop-authored row (`outcome=unknown`) instead of a rich, LLM-authored one.

**One-time production sheet cleanup (`exit_summary`/`summary`), not a code change**
- The real sheet had never had the manual header rename `telemetry/README.md` already documented when `summary` replaced `exit_summary` -- both columns now hold real, disjoint data (old rows in one, everything since 2026-08-05 in the other). New `migrateExitSummaryColumn()` (Apps Script) copies `exit_summary` into blank `summary` cells; not automated end-to-end since deleting the old column is harder to reverse than copying into one.

**`telemetry-emit.sh` -- delivery itself now retries, instead of a bare fire-and-forget POST**
- The original `curl --max-time 3`, backgrounded and never checked, could silently lose a correctly-invoked event on a cold Apps Script instance (Google's own web apps commonly take several seconds to wake from idle). Send is now a longer-timeout (15s -- safe to lengthen since it was never actually bounding the caller's wait) attempt that checks the response *body* for `"ok":true` (Code.gs always returns HTTP 200 even for a rejected token or a server exception, so the status code alone proves nothing), queues to `~/.claude/.thememate-usage-fallback.jsonl` (capped 1000 lines) on any failure, and drains that queue on the next successful send (truncating after each delivered row, not after the whole loop, so an interrupted drain can't re-send what it already delivered).

**`install.sh` -- new `--doctor` check-only mode; new shared `thememate-hooks.py`**
- Factored the "which hooks are expected" list and the settings.json read/write logic out of three separate copies (install.sh's registration, skill-updater.sh's daily self-heal, and this new doctor check) into one file, `thememate-hooks.py`, installed and self-updated like the other helper scripts.
- Safer writes: back up the existing `settings.json` before writing, write the merged result to a temp file in the same directory, re-parse *that* file to confirm valid JSON, only then atomically replace the original; refuse to touch a `settings.json` that fails to parse at all rather than guessing. `bash install.sh --doctor` reports hook-registration/script-presence status without changing anything -- verified it correctly flags a hook manually deleted from settings.json (the exact incident class documented in a sibling project) and that a normal run self-heals it.

**Two additional bugs found only by testing against the real production endpoint, not local mocks**
- `urllib`/`ssl` on macOS's python.org-distributed Python (used for the retry queue's send step, initially) does not use the system certificate trust store the way `curl` does -- it failed every single HTTPS request with a certificate-verification error, silently queueing 100% of real traffic. Local tests never caught this because they used plain-HTTP test servers. Fixed by shelling out to `curl` for the actual transport (python only wraps it for the response-body check and retry logic); `curl` has always worked correctly here.
- Even after that fix, `curl -L` (auto-follow redirects) reproducibly mishandled the cross-host redirect Apps Script's webapp always issues (`script.google.com` -> `script.googleusercontent.com`) under HTTP/2 on this curl build -- surfacing as a generic Google Drive 404, or (forcing `--http1.1`) an explicit "411 Length Required," i.e. curl replaying a malformed POST at the second hop instead of the plain GET that endpoint actually expects. Fixed by following the redirect as an explicit, separate `curl` call to the first response's `Location` header instead of relying on `-L` -- confirmed 100% reliable across repeated live tests where `-L` failed every time.
- Also renamed two Apps Script functions (`reconcileStaleSessions_` -> `reconcileStaleSessions`, `migrateExitSummaryColumn_` -> `migrateExitSummaryColumn`): Apps Script treats a trailing-underscore function name as private and excludes it from the Add Trigger dialog's function dropdown entirely (confirmed via Google's own community forum -- the official docs page doesn't mention it), so neither could ever be wired to a trigger under their original names. This repo's other internal helpers (`upsertRow_`, `ensureHeaders_`, etc.) correctly keep the underscore since they're never meant to be triggered directly.

### [2.15.0] 2026-08-10: Deterministic no-data-miss telemetry backstop + narrative summary

Superseded by 2.16.0. Archived at `versions/SKILL-2.15.0.md`.

**Root cause:** three prior fixes (2.11.0, 2.12.0, 2.14.0 below) all added more prose/TodoWrite reminders to make the LLM itself more likely to remember to fire `session_start`/`session_heartbeat`/`session_end` -- and 2.14.0's own postmortem shows that still failing live. Every one of those events lived entirely inside "the LLM remembers to run a bash command while executing the rest of a long task," with nothing external ever verifying it happened. This version doesn't add a fourth reminder -- it adds a mechanism outside the LLM's control that closes the gap regardless of whether the reminder works.

**New: `thememate-autolog.py` (repo root, installed to `~/.claude/thememate-autolog.py`)**
- Registered by `install.sh`/`skill-updater.sh` on Claude Code's `Stop` (fires every completed turn) and `SessionEnd` (fires once at session termination) hooks -- confirmed live, not assumed: an `InstructionsLoaded` hook (the original plan for cheaply detecting "this session touched ThemeMate") never fired in three separate test sessions despite the skill demonstrably loading, so detection instead rides on `Stop`'s own first invocation for a session, which did fire reliably.
- `Stop`: incrementally scans each in-scope session's own transcript (byte-offset tracked, cost independent of transcript size) for `session_start`/`session_end` calls already made, scoped strictly to `Bash` tool_use `input.command` text -- not transcript text generally, since Section 14's own documentation contains the literal string `telemetry-emit.sh session_start` in its examples, which would otherwise false-positive the instant the skill loads. If no `session_start` appears after a grace period (3 stops *and* 90 elapsed seconds -- both, so BRAND_DISCOVER's Playwright cold start inside turn 1 doesn't trigger a false backstop), fires a synthetic one itself (`logged_by=stop_hook`).
- `SessionEnd`: closes any `session_id` left open with a synthetic `session_end` (`logged_by=session_end_hook`, `outcome=unknown`), deliberately omitting `summary`/`role`/`mode`/etc. so the row's existing columns (set by the LLM's own last heartbeat) are preserved by the sheet's upsert-merge rather than blanked.
- Confirmed live: `SessionEnd` fires on a graceful exit and on a SIGTERM-based kill, but did **not** fire when the process was sent `SIGKILL` -- so this hook alone isn't a complete backstop.

**New: `reconcileStaleSessions()` in `telemetry/apps-script/InstallRollup.gs` (hand-maintained)**
- Closes the gap the client-side hooks can't, by construction (a hard-killed process runs no hooks at all): a daily sweep closes any `events` row with a `session_id`, blank `outcome`, and `received_at` older than 24h with `outcome=unknown, logged_by=server_sweep`, via `upsertRow_` in-process (no HTTP round trip).

**`telemetry/schema.json` / generated artifacts**
- New `outcome=unknown` enum value (reserved for the backstop layers -- the LLM never uses it itself, since it always knows its own real outcome by `session_end`).
- New `logged_by` field (`llm | stop_hook | session_end_hook | server_sweep`) -- its absence marks an LLM-authored row; its presence measures, per layer, how often the backstop actually had to compensate.
- New `field_max_len` schema key: a per-field override on top of the existing global `max_len` (128). `summary` is set to 400 -- see below.

**Section 14 -- `summary` becomes an append-only pointer-log**
- Previously a single evolving one-liner, overwritten at each checkpoint -- now an append-only log of short `<checkpoint>: <what happened>` segments joined with ` | `, held as running state and resent in full on every `session_heartbeat`/`session_end` call (the sheet never concatenates server-side). On overflowing the new 400-char cap, the oldest segment(s) drop first, keeping the newest plus the original `session_start` segment as a stable anchor. Makes a session's whole arc -- including one abandoned mid-way, closed only by the backstop -- legible from one cell instead of showing only its last-known status.
- Brief new note on the backstop's existence and the `logged_by`/`outcome=unknown` conventions above, so the LLM path isn't confused seeing hook-authored rows -- informational only, doesn't change the LLM's own emit obligations.

### [2.14.0] 2026-08-06: Telemetry as a first-class step in the executed sequence

Superseded by 2.15.0. Archived at `versions/SKILL-2.14.0.md`.

**Root cause:** a live THEME_EDIT session emitted zero telemetry for 6 user turns -- no `session_start`, no `session_heartbeat`, no `session_id` generated at all -- despite 2.12.0's TodoWrite forcing function (Section 1 step 2). That instruction lives in prose read once at session start; it has no dependency or blocking relationship with any function in the actual Section 4 FUNCTION SEQUENCE the model executes step-by-step, so it's easy to never circle back to. Backfilled `session_start` + a catch-up `session_heartbeat` manually once the gap was noticed mid-session.

**Section 4 -- ROLE x MODE -> FUNCTION SEQUENCE**
- Every row in all three tables (THEME_INSPECT, THEME_EDIT has-access, THEME_EDIT no-access) now starts with `session_start ->`. This doesn't move where it actually fires (still Section 1 step 2, before the table is even consulted) -- it's a checkpoint so a sequence can't be read and started without a visible reminder, with a fallback instruction to fire it late if it somehow hasn't happened yet.

**Section 5 -- EDIT / TEST**
- New "Telemetry checkpoint" step at the top of both functions: check whether `session_heartbeat` has fired in the last 5 turns before continuing. These are the two functions where a session's turns accumulate fastest with no other natural forcing function in between (EDIT's fix loop and TEST's fix loop can each run several turns unattended).

**Section 2 -- ROLES, rule 2 (cached role)**
- Flagged as the highest-risk path for the same gap: a cached role plus an unambiguous request (Section 3's MODE table also resolves silently) means a session can start with zero chat back-and-forth -- nothing naturally prompts the model to pause and run the `session_start` TodoWrite/emit step, which matches the incident's actual conditions (returning `swym_acq` operator, unambiguous bug-fix request). Rule 2 now says explicitly to fire `session_start` anyway.

### [2.13.0] 2026-08-05: Total session tokens in telemetry

Superseded by 2.14.0. Archived at `versions/SKILL-2.13.0.md`.

**Section 14 -- TELEMETRY**
- New `tokens` field, tracked alongside `turns`/`session_duration_min` as a third running counter, reported on `session_heartbeat` and `session_end`. Best-effort and exact-when-resolvable, never estimated: when running inside Claude Code (the CLI) with Bash access, computed by reading this session's own transcript file (`~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl` -- the session UUID is read from context already available, e.g. the "Scratchpad Directory" path, never discovered by listing the projects directory) and summing `input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens` across the session. Omitted entirely in Claude Desktop or any other host with no equivalent readable transcript, rather than guessed from message length or any other proxy.
- **Dedup by `requestId` before summing** -- a single API call is frequently split across multiple `assistant`-type JSONL lines (one per content block: text, tool_use, etc.), each carrying an identical copy of that call's `usage`. Verified against this session's own transcript: naively summing every `assistant` line overcounted by ~68% (16.5M vs the correct 9.8-10.2M) because 56 of 85 distinct API calls were logged as more than one line. Keyed on `requestId` (one `usage` per unique request) instead.
- Recomputed fresh on every `session_heartbeat`/`session_end` rather than tracked as a running delta -- the transcript already holds the full history, re-summing it is cheap and avoids drift.

**`telemetry/schema.json` / generated artifacts**
- `tokens` added to `accepted_keys` and `column_order` (no enum, numeric like `turns`/`lines_written`). Regenerated `telemetry-emit.sh`'s embedded schema block and `telemetry/apps-script/Code.gs` via `scripts/generate_telemetry_artifacts.py`.

**`telemetry/apps-script/InstallRollup.gs` (hand-maintained)**
- `avg_tokens` added to the per-install rollup, mirroring `avg_turns` exactly (sum/count accumulation, same falsy-safe `cellValue_` read, same column placement next to `avg_turns`).

### [2.12.0] 2026-08-05: Telemetry forcing function, Playwright cold-start, account_name as free text

Superseded by 2.13.0. Archived at `versions/SKILL-2.12.0.md`.

**Section 1 / Section 14 -- session_start forcing function**
- `session_start` telemetry was a memory-held obligation with no forcing function -- nothing surfaced a skip, and one happened in practice. Both the top-level session-start steps (Section 1) and Section 14's own `session_start` instructions now say to add a TodoWrite item at the exact point MODE is classified (in_progress before resolving fields, completed right after the emit call), instead of just narrating the intent to emit it.

**Section 6 -- BROWSER SETUP: fresh-machine Playwright registration**
- New Step 0: `claude mcp list | grep -i playwright` before anything else. Previously Step 5 assumed a Playwright MCP server entry already existed and only covered adding the CDP arg to it -- on a fresh machine with no entry at all, there was no step for registering one from scratch. Step 0 now runs `claude mcp add -s user playwright -- npx -y @playwright/mcp@latest --cdp-endpoint http://127.0.0.1:9222` directly (folds Step 5's arg into the same command) and calls out that this requires a session restart before any browser tool becomes callable -- Step 5 is now explicitly the "entry already exists" path only.

**Section 5 -- BRAND_DISCOVER pre-step: distinguish tool-absent from CDP-unreachable**
- The CDP connectivity pre-step only detected "CDP unreachable" (`ECONNREFUSED`), which assumes a browser tool exists to even throw that error. A session with no Playwright MCP server registered at all is a different failure mode (Section 6 Step 0 fixes it, not Steps 1-4) and previously had no dedicated check. Pre-step now checks the browser tool is present at all before attempting the eval.

**Section 14 -- account_name as free text, not enum**
- The one-time `account_name` ask is now explicit that it must be a plain-text chat question, not a multiple-choice/enum-style tool prompt (e.g. `AskUserQuestion`) -- a "Skip / Share a name" choice can't capture the actual name in the same round trip and forces a second back-and-forth to get it.

**`telemetry-emit.sh` -- local audit trail**
- The `curl` send is backgrounded/disowned by design (never blocks) and its result was never checked, so there was no way on a given machine to tell an attempted-and-dropped event apart from one that was never attempted. New minimal local log (`~/.claude/.thememate-telemetry.log`, rotated to the last 500 lines) records `timestamp event=<event> session_id=<id>` right before every `curl` call -- no other payload fields, so it carries no more PII than what already left the machine.
- Log writes and rotation run under `umask 077`, with an explicit `chmod 600` backstop for a pre-existing log file -- since it records usage timing and session_ids, it shouldn't inherit the process's (often world-readable) default umask. Rotation cleans up its `.tmp` file on a failed `tail` instead of leaving it stale.

### [2.11.0] 2026-08-05: Self-heal skill-updater.sh/telemetry-emit.sh on existing installs

Superseded by 2.12.0. Archived at `versions/SKILL-2.11.0.md`.

**Section 14 -- TELEMETRY**
- New self-heal check, once per session before anything else in this section: `grep -q "sync_if_sha_changed" ~/.claude/skill-updater.sh`. If that fails (missing, or predates the self-update mechanism added to `skill-updater.sh`), fetch fresh copies of `skill-updater.sh` and `telemetry-emit.sh` directly from the repo via `gh api` and overwrite the local ones.
- Closes a bootstrap gap: `skill-updater.sh`'s own daily self-update logic can only run if it's already the code present on disk -- an existing install stuck on the pre-self-update version had no path to ever pick up that capability without someone manually re-running `install.sh`. This check lives in `SKILL.md` specifically because `SKILL.md` is the one file that reliably already auto-updates on every existing install.
- Respects the `.thememate-telemetry-optout` marker for the `telemetry-emit.sh` half, same as `skill-updater.sh`'s own sync does. Self-limiting: once `skill-updater.sh` is current, the grep passes immediately on every future session and this does nothing further.

### [2.10.0] 2026-08-05: usecase/summary/usecase_met, feature and vertical in telemetry

Superseded by 2.11.0. Archived at `versions/SKILL-2.10.0.md`.

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
