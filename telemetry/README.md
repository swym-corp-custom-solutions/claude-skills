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
- The daily `heartbeat` event from `skill-updater.sh` (no `session_id`, no session fields -- a plain install-is-alive ping) writes to its own `heartbeat` sheet/tab instead of `events`, with a fixed minimal column set (`received_at`, `ts`, `install_id`, `skill`, `skill_version`) that doesn't evolve alongside `schema.json`'s session-oriented columns

## CI guard

Workflow [telemetry-schema-check.yml](../.github/workflows/telemetry-schema-check.yml) fails PRs if generated artifacts are stale.

## Apps Script deployment options

1. Manual copy/paste
- Open your Apps Script project
- Replace script content with [telemetry/apps-script/Code.gs](apps-script/Code.gs)
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

If THEMEMATE_TOKEN is not set, requests are accepted without token validation.
