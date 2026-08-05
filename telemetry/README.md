# Telemetry Schema Automation

This folder makes telemetry schema changes a one-file update.

## Source of truth

- Edit [telemetry/schema.json](schema.json)
- Do not manually edit generated blocks in [telemetry-emit.sh](../telemetry-emit.sh) or generated Apps Script output in [telemetry/apps-script/Code.gs](apps-script/Code.gs)

## Regenerate artifacts

Run from repo root:

```bash
python3 scripts/generate_telemetry_artifacts.py
```

This updates:
- [telemetry-emit.sh](../telemetry-emit.sh): accepted keys and enums block
- [telemetry/apps-script/Code.gs](apps-script/Code.gs): receiver logic with header auto-migration

## How new columns are handled

When you add a key in [telemetry/schema.json](schema.json):
1. Add key to accepted_keys
2. Add key to column_order
3. Add enum constraints in enums if needed
4. Regenerate artifacts

At runtime, Apps Script runs header sync on every event:
- Existing columns are preserved
- Missing schema columns are appended to row 1 automatically
- Rows are written by header name, not fixed index
- Events carrying a `session_id` upsert: if a row with that `session_id` already exists, the event's fields are merged onto it (only the columns present on this event overwrite; everything else -- role, store_domain, git_org, etc. set by an earlier event in the same session -- is left untouched). A new row is only appended the first time a `session_id` is seen
- The daily `heartbeat` event from `skill-updater.sh` (no `session_id`, no full session fields -- a plain install-is-alive ping) writes to its own `heartbeat` sheet/tab instead of `events`, **upserted to one row per `install_id`** (not appended -- see `upsertHeartbeatRow_` in `Code.gs`). Its column set is `install_id`, `first_seen`, `last_seen`, `initial_version`, `current_version`, `ping_count`, plus whatever keys are listed in `schema.json`'s `heartbeat_keys` array (currently `email_domain`, `account_name`) -- the small subset of session-oriented fields that are cheap enough to resolve without an LLM or a live ThemeMate session, so idle installs still carry an identity signal. `first_seen`/`initial_version` are write-once; `last_seen`/`current_version` advance on every ping; `ping_count` increments on every ping and doubles as a distinct-days-active count, since `skill-updater.sh`'s daily lock guarantees at most one ping per install per calendar day. Add a key to `heartbeat_keys` (it must already be in `accepted_keys`) and regenerate to extend the passthrough fields; don't hand-edit `HEARTBEAT_COLUMNS` or `upsertHeartbeatRow_` in `Code.gs` directly.

**Migrating an existing `heartbeat` tab:** rows written before this upsert behavior shipped are raw per-day log rows in the old shape (`received_at, ts, install_id, skill, skill_version`) and won't fit the new columns. Rename or archive the old tab (e.g. to `heartbeat_archive`) before redeploying, so `getOrCreateSheet_` creates a fresh `heartbeat` tab with clean headers -- adopting an old row in place would leave `first_seen`/`initial_version` permanently blank (they're write-once and the old rows never had those columns).

**Renaming `exit_summary` to `summary`:** unlike adding a new key, a rename isn't handled by header auto-migration -- `ensureHeaders_` only appends columns it doesn't recognize, so leaving this to run on its own would add a new `summary` column while the old `exit_summary` column (and its history) sits frozen alongside it. Instead, manually rename the `exit_summary` header cell to `summary` directly in the `events` sheet before redeploying -- since columns are matched by header name, existing data and new data then share one continuous column with no code-side migration needed.

## Per-install rollup

[telemetry/apps-script/InstallRollup.gs](apps-script/InstallRollup.gs) is a second, **hand-maintained** file in the same Apps Script project -- the generator never touches it. `buildInstallRollup()` reads the `events` and `heartbeat` sheets and writes one row per `install_id` to an `install_rollup` sheet (first/last seen, version drift, identity, session/day counts, outcome and success/error rates). Since `heartbeat` is itself already one row per install, its side of the rollup just reads `first_seen`/`last_seen`/`initial_version`/`current_version`/`ping_count` directly; only the `events` side (still one row per session) needs to reduce across many rows. Run it on demand via the sheet's "Telemetry -> Rebuild Install Rollup" menu (added by this file's `onOpen()`), or set up a daily refresh once via the Apps Script Triggers UI:
```
ScriptApp.newTrigger('buildInstallRollup').timeBased().everyDays(1).atHour(6).create()
```
After a fresh Apps Script project setup, copy both `Code.gs` and `InstallRollup.gs` into the project -- `InstallRollup.gs` reuses `Code.gs`'s `SHEET_NAME`/`HEARTBEAT_SHEET_NAME` constants directly (both files share one project's global scope), so it won't run correctly on its own.

## CI guard

Workflow [telemetry-schema-check.yml](../.github/workflows/telemetry-schema-check.yml) fails PRs if generated artifacts are stale.

## Apps Script deployment options

1. Manual copy/paste
- Open your Apps Script project
- Replace script content with [telemetry/apps-script/Code.gs](apps-script/Code.gs)
- Also copy in [telemetry/apps-script/InstallRollup.gs](apps-script/InstallRollup.gs) as a second file in the same project (hand-maintained, not generated -- see "Per-install rollup" above)
- Deploy web app

2. Git-based with clasp (recommended)
- Keep Apps Script project linked to [telemetry/apps-script](apps-script)
- Run clasp push after regeneration
- Optional: add a deployment workflow using clasp credentials

## Auth token setup

The receiver checks Script Property THEMEMATE_TOKEN when present.

Set it once in Apps Script:
- Project Settings -> Script properties -> add key THEMEMATE_TOKEN
- Value should match TOKEN in [telemetry-emit.sh](../telemetry-emit.sh)

**Always set THEMEMATE_TOKEN.** This is a public web app URL -- if THEMEMATE_TOKEN is left unset, the receiver accepts requests without any token validation at all. Leaving it unset is not recommended outside of local/manual testing.
