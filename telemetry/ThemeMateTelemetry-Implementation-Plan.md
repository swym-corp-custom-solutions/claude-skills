# ThemeMate Telemetry Workbook: Gap Analysis and Implementation Plan

## What ThemeMate Telemetry.xlsx is

`telemetry/ThemeMate Telemetry.xlsx` is an exported telemetry analysis workbook used for reporting and QA. In the updated export it contains six sheets:

- `events`: session-level telemetry rows (upserted by `session_id` over time)
- `install_rollup`: one row per `install_id` aggregate metrics
- `heartbeat`: one row per `install_id` heartbeat summary
- `Pivot Table 1`: dashboard pivot over the above data
- `Calc_Data`: helper calculations feeding dashboard views
- `Metrics Dashboard`: curated dashboard/summary sheet

The workbook also includes pivot cache and drawing artifacts, confirming it is a reporting dashboard export rather than a source-of-truth runtime datastore.

## Findings and Gaps

### 1) Legacy schema drift in events
- Expected schema columns are present, but `events` has one extra legacy column: `exit_summary`.
- Current schema and code use `summary`, not `exit_summary`.
- Risk: reporting confusion, duplicate semantics, and stale formulas/pivots referencing legacy field names.

### 2) Identity field coverage is historically low
Observed in this workbook snapshot:
- `events.account_name`: missing 86/103 (83.5%)
- `events.email_domain`: missing 82/103 (79.6%)
- `heartbeat.account_name`: missing 11/15 (73.3%)
- `heartbeat.email_domain`: missing 4/15 (26.7%)

Interpretation:
- This snapshot contains historical rows from before identity backfills and no-skip enforcement.
- Existing rollups are therefore biased toward blank identity dimensions.

### 3) High missingness in operational session fields
Observed in `events`:
- `store_domain`: missing 77/103 (74.8%)
- `platform`: missing 55/103 (53.4%)
- `summary`: missing 61/103 (59.2%)
- `mode`: missing 37/103 (35.9%)

Additional data quality notes:
- `session_id` missing 5/103 (4.9%)
- `outcome` missing 12/103 (11.7%)

### 4) Install-id reuse opportunity is real and should be first-class

Re-analysis shows strong deterministic reuse potential using existing rows keyed by `install_id`:

- Rows needing identity fill (`account_name` and/or `email_domain`): 99
- Rows fillable for `account_name` from existing install-linked data: 42
- Rows fillable for `email_domain` from existing install-linked data: 46

Interpretation:
- We do not need to ask each session.
- If identity exists for an `install_id` in `heartbeat` or `install_rollup`, reuse it for missing fields in `events` rows tied to that same `install_id`.

Interpretation:
- Many rows are likely heartbeat/feedback-only, early versions, or partial session events.
- Dashboards that assume complete rows may under-report platform/store-level reliability.

### 5) Workbook is static and can become stale
- XLSX is a point-in-time export.
- Without refresh discipline, it may not reflect post-fix behavior now implemented in scripts.

## Implementation Plan

## Phase 1: Stabilize ingestion and identity completeness (Now)
1. Keep the current emitter behavior that enforces non-blank identity fields:
   - `account_name` auto-resolve with fallback
   - `email_domain` fallback to `unknown.local`
2. Keep heartbeat emission minimal (`heartbeat` only) and rely on emitter attachment for identity.
3. Apply install-scoped reuse policy in telemetry processing:
   - If an incoming row for `install_id=X` has blank `account_name` or `email_domain`, look up last known values for `X` from `heartbeat` first, then `install_rollup`.
   - Fill only missing values, never overwrite non-blank values.
   - Do not prompt for name on sessions where install-level identity already exists.
4. Verify with a 3-day observation window that new rows have:
   - `events.account_name` non-blank
   - `events.email_domain` non-blank
   - `heartbeat.account_name` non-blank
   - `heartbeat.email_domain` non-blank

Acceptance criteria:
- For rows with `received_at >= deployment_time`, identity missingness is 0% in both `events` and `heartbeat`.

## Phase 2: Clean schema drift in reporting layer (1 day)
1. In Google Sheet / reporting source, rename legacy header `exit_summary` to `summary` if still present.
2. Update pivot fields and calculated columns to use `summary` exclusively.
3. In workbook export process, remove/deprecate references to `exit_summary`.

Acceptance criteria:
- No dashboard component references `exit_summary`.
- `summary` is the single narrative status field end-to-end.

## Phase 3: Historical backfill using install_id reuse (2-3 days)
1. Do not overwrite historical rows with guessed values.
2. Backfill deterministic fields only where safe and install-linked:
   - `email_domain`: derive from same-install `heartbeat`, fallback to `install_rollup`.
   - `account_name`: derive from same-install `heartbeat`, fallback to `install_rollup`.
3. Only backfill rows with matching non-blank `install_id`; skip rows with missing `session_id` + missing `install_id`.
4. Mark backfilled values as derived in migration notes (or a dedicated provenance column if accepted).
5. Leave ambiguous installs untouched (`unknown.local` / `unknown-operator` policy applies only to new events unless explicit migration is approved).

Acceptance criteria:
- Historical identity coverage improves materially without introducing guessed or conflicting data.
- Backfill logic is reproducible and auditable.

## Phase 4: Strengthen dashboard semantics (1-2 days)
1. Segment metrics by event type (`session_start`, `session_heartbeat`, `session_end`, `feedback`, `heartbeat`) before calculating completion/success rates.
2. Use `outcome` and `logged_by` for reliability dashboards.
3. Exclude rows without `session_id` from session funnel metrics.
4. Add data quality KPIs:
   - Identity completeness (% non-blank account/domain)
   - Session closure rate (% rows with `outcome` present)
   - Field completeness per role/platform

Acceptance criteria:
- Dashboard can distinguish ingestion quality from product reliability.

## Phase 5: Export governance for XLSX artifact (ongoing)
1. Treat `ThemeMate Telemetry.xlsx` as generated reporting output.
2. Define refresh cadence (daily or weekly) and naming convention with date stamp (e.g., `ThemeMate Telemetry-YYYY-MM-DD.xlsx`).
3. Optionally avoid committing binary exports to repo and keep only scripts/docs, unless explicit archival is required.

Acceptance criteria:
- Consumers know whether they are looking at live sheet data or point-in-time export.

## Install-ID Reuse Policy (No Per-Session Ask)

Policy:

1. Ask for operator name only when local cache is missing and no reusable install-level identity exists.
2. Once captured for an install, reuse it on all subsequent rows for that `install_id`.
3. Never ask again in later sessions for the same install unless identity is explicitly reset.
4. For historical rows, enrich by `install_id` join; do not infer from free text.

Lookup precedence for reuse:

1. Current event payload
2. Local cache (`~/.claude/.thememate-account-name`)
3. Same-install `heartbeat` row
4. Same-install `install_rollup` row
5. Fallback sentinel (`unknown-operator` / `unknown.local`)

## Suggested execution order
1. Phase 1 verification (already largely implemented in scripts).
2. Phase 2 schema cleanup.
3. Phase 3 historical backfill (recommended, deterministic via `install_id`).
4. Phase 4 dashboard semantics update.
5. Phase 5 governance.

## Quick verification checklist
- Trigger one `heartbeat` and one full ThemeMate session.
- Confirm in telemetry sink:
  - `account_name` populated
  - `email_domain` populated and domain-shaped
  - `summary` populated on session-end flows
  - no new `exit_summary` writes
- Rebuild `install_rollup` and verify identity fields resolve for fresh installs.

## Detailed execution runbook

For implementation-ready steps (join precedence, conflict policy, dry-run and write phases, rollback, acceptance checks), see:

- [Identity-Reuse-Backfill-Detailed-Plan.md](Identity-Reuse-Backfill-Detailed-Plan.md)
