# Identity Reuse and Backfill: Detailed Implementation Plan

## Goal

Ensure `account_name` and `email_domain` are populated consistently without asking every session.

Core rule:
- Reuse identity by `install_id` whenever already known.
- Ask only when identity is missing and no deterministic install-level value exists.

## Scope

In scope:
- New event ingestion behavior (forward fill by `install_id`)
- Historical backfill for `events` using deterministic joins
- Reporting validation after fill

Out of scope:
- Guessing identity from free text
- Overwriting non-blank identity fields
- Filling rows without a usable `install_id`

## Data Sources and Trust Order

For each target row in `events`, resolve missing identity fields with this precedence:

1. Current event payload value
2. Local cache attached by emitter
3. Same-install row in `heartbeat`
4. Same-install row in `install_rollup`
5. Fallback sentinel
   - `account_name = unknown-operator`
   - `email_domain = unknown.local`

Notes:
- `heartbeat` is preferred over `install_rollup` because it is a direct per-install identity source.
- `install_rollup` is secondary because it is derived.

## Functional Requirements

FR-1: No per-session re-ask
- If `install_id` already has non-blank identity in `heartbeat` or `install_rollup`, do not ask again.

FR-2: Fill missing only
- Update identity fields only when target value is blank.
- Never replace non-blank values during backfill.

FR-3: Deterministic only
- Only fill rows with non-blank `install_id`.
- Skip rows where `install_id` is missing.

FR-4: Conflict-safe
- If multiple distinct candidate values exist for the same `install_id`, apply conflict policy (below) and do not guess.

FR-5: Auditability
- Produce migration summary counts and conflict reports.
- Keep before/after snapshots (export or tab copy) before applying writes.

## Conflict Policy

For each `install_id` and field (`account_name`, `email_domain`):

1. Collect candidates from `heartbeat` and `install_rollup`.
2. Normalize values:
   - Trim whitespace
   - Collapse repeated spaces
   - Lowercase `email_domain`
3. Remove empty values.
4. If one unique value remains, use it.
5. If more than one unique value remains:
   - Prefer value from `heartbeat` if present and non-sentinel.
   - Else keep unresolved and log as conflict.
6. Never use a value containing `@` for `email_domain`.
7. Never write `skip` as `account_name`.

## Historical Backfill Procedure

## Step A: Preflight

1. Export current workbook/sheet snapshot.
2. Confirm required columns exist in `events`:
   - `install_id`, `account_name`, `email_domain`
3. Confirm source columns exist in `heartbeat` and `install_rollup`.
4. Run dry-run only (no writes).

## Step B: Dry-run analysis output

Dry-run must produce:

- Total rows scanned
- Rows eligible (`events` rows with non-blank `install_id` and missing identity)
- Rows fillable for `account_name`
- Rows fillable for `email_domain`
- Rows unresolved due to missing source identity
- Rows unresolved due to conflicts
- Distinct conflict install_ids with candidate sets

Recommended dry-run artifacts:
- `backfill-summary.json`
- `backfill-conflicts.csv`
- `backfill-preview.csv` (row id + proposed values)

## Step C: Apply write

1. Write only rows approved by dry-run (deterministic fills).
2. Perform idempotent updates:
   - Skip if target field became non-blank after dry-run
3. Re-run dry-run after write to confirm:
   - zero newly proposed deterministic fills

## Step D: Post-write validation

1. Recompute completeness metrics for:
   - `events.account_name`
   - `events.email_domain`
2. Rebuild `install_rollup`.
3. Refresh dashboard tabs/pivots.

## Runtime Ingestion Plan (Forward)

To avoid future historical gaps:

1. Keep emitter-side non-blank enforcement.
2. Add receiver-side install reuse on ingest path:
   - On incoming row with blank identity and non-blank `install_id`, consult `heartbeat` then `install_rollup` and fill before write.
3. If still unresolved, keep emitter sentinel values.

Result:
- New rows should no longer accumulate identity blanks.

## Acceptance Criteria

Data quality:
1. For rows created after deployment, identity missingness is 0%.
2. Historical backfill improves coverage by the deterministic amount from dry-run.
3. No non-blank identity values are overwritten.

Safety:
1. Backfill is idempotent.
2. Conflict rows are not auto-filled.
3. Rollback snapshot exists.

Operational:
1. No additional operator prompt appears when install-level identity already exists.
2. Dashboard metrics continue to compute without formula breakage.

## Rollback Plan

If any issue occurs:

1. Restore pre-backfill sheet snapshot (or workbook export).
2. Revert code/config changes in receiver.
3. Re-run validation metrics to confirm baseline restored.

## Implementation Tasks

## Task 1: Dry-run tool
- Build a read-only analyzer that emits summary, conflicts, and preview files.
- Owner: telemetry engineering
- Est: 0.5 day

## Task 2: Apply tool
- Build idempotent writer for approved fills.
- Owner: telemetry engineering
- Est: 0.5 day

## Task 3: Receiver ingestion reuse
- Add install-id identity reuse in Apps Script ingest path for blank identity inputs.
- Owner: Apps Script maintainer
- Est: 0.5 day

## Task 4: Validation and dashboard refresh
- Recompute metrics, refresh pivots/dashboards, publish before/after summary.
- Owner: analytics
- Est: 0.5 day

Total estimate: 2 days

## Reporting Template (Before/After)

Include in rollout note:

- Timestamp of backfill
- Rows scanned
- Rows updated (account_name)
- Rows updated (email_domain)
- Conflict install_ids count
- Unresolved install_ids count
- Missingness before vs after (both identity fields)

## Open Decisions

1. Should conflict rows be routed to a manual review tab for resolution?
2. Should provenance columns be added (`identity_source_account`, `identity_source_domain`) or handled only in migration logs?
3. Should sentinel values be excluded from rollup identity dimensions in dashboard slices?

## Implementation handoff

Execution-ready checklist with exact files, functions, script I/O contracts, and validation commands:

- [Identity-Reuse-Execution-Checklist.md](Identity-Reuse-Execution-Checklist.md)
