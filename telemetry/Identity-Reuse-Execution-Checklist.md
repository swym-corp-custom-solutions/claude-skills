# Identity Reuse Execution Checklist

## Objective

Implement deterministic identity reuse/backfill so `account_name` and `email_domain` are reused by `install_id`, not re-asked per session.

## Deliverables

1. Receiver-side runtime reuse for incoming events
2. Offline dry-run/apply backfill tool for historical rows
3. Validation scripts and reproducible metrics checks
4. Rollout + rollback runbook execution

## File-Level Change Plan

## A) Runtime receiver changes

File:
- `telemetry/apps-script/Code.gs`

Changes:
1. Add helper: `resolveInstallIdentity_(installId)`
2. Add helper: `normalizeIdentityValue_(key, value)`
3. Add helper: `applyInstallIdentityFallback_(normalizedPayload)`
4. Call `applyInstallIdentityFallback_` inside `doPost` after `normalizePayload_` and before `upsertRow_`

Behavior:
- If event has non-blank `install_id` and either `account_name` or `email_domain` is blank:
  - Read `heartbeat` row for same install first
  - Fallback to `install_rollup`
  - Fill only missing fields
- Never overwrite non-blank incoming identity values

Notes:
- `heartbeat` is source-of-truth for install identity.
- `install_rollup` is fallback only.

## B) Backfill tool (offline)

New file:
- `scripts/telemetry_identity_backfill.py`

Modes:
- `dry-run`
- `apply`

Inputs:
- `--xlsx telemetry/ThemeMate Telemetry.xlsx`
- `--output-dir telemetry/backfill-output`
- `--mode dry-run|apply`
- `--prefer heartbeat,install_rollup` (default this order)
- `--allow-sentinels true|false` (default false for historical backfill)

Outputs:
- `backfill-summary.json`
- `backfill-preview.csv`
- `backfill-conflicts.csv`
- `backfill-unresolved.csv`
- In `apply` mode: updated workbook copy at
  - `telemetry/backfill-output/ThemeMate Telemetry.backfilled.xlsx`

Constraints:
- Do not modify original input file in place
- Idempotent apply
- Skip rows with blank `install_id`
- Skip rows where target field already non-blank

## C) Optional helper script for metric check

New file:
- `scripts/telemetry_identity_metrics.py`

Purpose:
- Print completeness stats before/after for
  - `events.account_name`
  - `events.email_domain`
  - `heartbeat.account_name`
  - `heartbeat.email_domain`

## Function-Level Contracts

## `resolveInstallIdentity_(installId)` in `Code.gs`

Input:
- `installId: string`

Output:
- Object shape:
  - `{ account_name: string, email_domain: string, source_account: string, source_domain: string }`

Rules:
1. Read from `heartbeat` by `install_id`
2. If missing field, fallback from `install_rollup`
3. Return empty strings when unresolved

## `applyInstallIdentityFallback_(payload)` in `Code.gs`

Input:
- normalized payload object from `normalizePayload_`

Output:
- payload object with missing identity fields potentially filled

Rules:
1. No-op if no `install_id`
2. No-op for non-blank `account_name` / `email_domain`
3. Fill only blanks
4. Validate `email_domain` shape with existing domain pattern

## `telemetry_identity_backfill.py`

### `dry_run(workbook_path, out_dir, prefer_order, allow_sentinels)`

Returns summary dict:
- rows_scanned
- rows_eligible
- rows_fillable_account
- rows_fillable_domain
- rows_conflict
- rows_unresolved
- conflict_install_ids_count

### `apply_backfill(workbook_path, out_dir, config)`

Returns summary dict:
- rows_updated_account
- rows_updated_domain
- rows_skipped_nonblank
- rows_skipped_no_install_id
- rows_skipped_conflict

## Conflict Handling Rules (must match both runtime + backfill)

1. Normalize candidates:
- trim
- collapse spaces
- lowercase domain

2. Reject invalid domain candidates:
- contains `@`
- fails domain regex

3. Reject account candidate `skip`

4. Candidate selection:
- single unique valid value -> use it
- multiple values:
  - choose `heartbeat` value if valid and non-sentinel
  - else unresolved conflict

## Verification Commands

## 1) Static checks

```bash
python3 -m py_compile scripts/telemetry_identity_backfill.py scripts/telemetry_identity_metrics.py
```

## 2) Dry-run

```bash
python3 scripts/telemetry_identity_backfill.py \
  --xlsx "telemetry/ThemeMate Telemetry.xlsx" \
  --mode dry-run \
  --output-dir telemetry/backfill-output
```

## 3) Apply to copy

```bash
python3 scripts/telemetry_identity_backfill.py \
  --xlsx "telemetry/ThemeMate Telemetry.xlsx" \
  --mode apply \
  --output-dir telemetry/backfill-output
```

## 4) Compare completeness before/after

```bash
python3 scripts/telemetry_identity_metrics.py --xlsx "telemetry/ThemeMate Telemetry.xlsx"
python3 scripts/telemetry_identity_metrics.py --xlsx "telemetry/backfill-output/ThemeMate Telemetry.backfilled.xlsx"
```

## 5) Rebuild rollup after apply (Apps Script)

- Run `buildInstallRollup` from Apps Script menu: Telemetry -> Rebuild Install Rollup

## Acceptance Test Matrix

1. Incoming event with non-blank install_id and blank account_name:
- Expected: account_name auto-filled from install identity source

2. Incoming event with non-blank install_id and blank email_domain:
- Expected: email_domain auto-filled and domain-valid

3. Incoming event with both identity fields already set:
- Expected: unchanged

4. Backfill row with blank install_id:
- Expected: unchanged, logged unresolved

5. Backfill row with conflicting candidates:
- Expected: unchanged, logged in conflicts

6. Apply run executed twice:
- Expected: second run reports zero additional updates

## Rollout Sequence

1. Implement runtime receiver fallback in `Code.gs`
2. Deploy Apps Script web app update
3. Run dry-run on latest workbook snapshot
4. Review conflicts and unresolved files
5. Run apply on workbook copy
6. Validate before/after metrics
7. Rebuild rollup and refresh dashboards

## Rollback

1. Revert Apps Script to prior version
2. Restore pre-backfill workbook snapshot
3. Re-run completeness metrics to confirm baseline

## Known Remaining Risks

1. Rows missing `install_id` remain unfillable deterministically
2. Conflicting identity values may require manual review queue
3. Sentinel-heavy data can skew dashboard identity dimensions if not filtered
