/**
 * Per-install telemetry rollup for ThemeMate.
 *
 * Hand-maintained -- NOT touched by scripts/generate_telemetry_artifacts.py.
 * Lives in the same Apps Script project as the generated Code.gs and reuses
 * its top-level constants (SHEET_NAME, HEARTBEAT_SHEET_NAME) directly, since
 * files in one Apps Script project share a single global scope.
 *
 * buildInstallRollup() reads the `events` and `heartbeat` sheets and writes
 * one row per install_id to a new `install_rollup` sheet: first/last seen,
 * version drift, identity (account_name/email_domain/git_org/role), usage
 * counts, and outcome/success/error rates. Full overwrite on every run --
 * simplest correct approach at this data volume.
 *
 * `heartbeat` is itself upserted to one row per install_id (see Code.gs's
 * upsertHeartbeatRow_), so its first_seen/last_seen/initial_version/
 * current_version/ping_count are read directly rather than scanned/reduced
 * across many historical rows -- only `events` (still one row per session,
 * many rows per install) needs the streaming min/max/count reduction.
 *
 * Run on demand via the "Telemetry" menu (onOpen below), or wire a daily
 * time-driven trigger once via the Apps Script Triggers UI:
 *   ScriptApp.newTrigger('buildInstallRollup').timeBased().everyDays(1).atHour(6).create()
 * Time triggers always run the latest saved code -- unlike the web app's
 * doPost, this isn't gated behind creating a new deployment version.
 */

const ROLLUP_SHEET_NAME = 'install_rollup';
const ROLLUP_COLUMNS = [
  'install_id',
  'first_seen',
  'last_seen',
  'initial_version',
  'current_version',
  'account_name',
  'email_domain',
  'git_org',
  'role',
  'platform',
  'session_count',
  'days_active',
  'completed_count',
  'blocked_count',
  'error_count',
  'scope_rejected_count',
  'success_rate',
  'error_rate',
  'avg_turns',
  'avg_tokens',
  'avg_session_duration_min',
  'satisfaction_positive',
  'satisfaction_neutral',
  'satisfaction_negative'
];

// `row[col[name]] || ''` would coerce a legitimate falsy value (e.g. numeric
// 0 for turns/ping_count) to an empty string, silently dropping it from
// averages/counts. Explicit undefined/null check instead.
function cellValue_(row, col, name) {
  if (col[name] === undefined) return '';
  const v = row[col[name]];
  return (v === undefined || v === null) ? '' : String(v);
}

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Telemetry')
    .addItem('Rebuild Install Rollup', 'buildInstallRollup')
    .addToUi();
}

function buildInstallRollup() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const installs = {};

  processEventsRollup_(installs, ss.getSheetByName(SHEET_NAME));
  processHeartbeatRollup_(installs, ss.getSheetByName(HEARTBEAT_SHEET_NAME));

  writeRollup_(ss, installs);
}

// `events`: one row per session_id, many rows per install -- still needs the
// streaming min/max/count reduction across rows.
function processEventsRollup_(installs, sheet) {
  if (!sheet) return;
  const values = sheet.getDataRange().getValues();
  if (values.length < 2) return;

  const headers = values[0];
  const col = {};
  headers.forEach(function (h, i) { col[h] = i; });
  if (col.install_id === undefined) return;

  for (let r = 1; r < values.length; r++) {
    const row = values[r];
    const installId = String(row[col.install_id] || '');
    if (!installId) continue;

    const getVal = function (name) { return cellValue_(row, col, name); };
    const receivedAtRaw = getVal('received_at');
    const receivedAt = receivedAtRaw ? new Date(receivedAtRaw).getTime() : null;
    const skillVersion = getVal('skill_version');

    const rec = getRollupRecord_(installs, installId);
    touchRollupRecord_(rec, receivedAt, skillVersion);
    updateRollupField_(rec, 'account_name', getVal('account_name'), receivedAt);
    updateRollupField_(rec, 'email_domain', getVal('email_domain'), receivedAt);
    updateRollupField_(rec, 'git_org', getVal('git_org'), receivedAt);
    updateRollupField_(rec, 'role', getVal('role'), receivedAt);
    updateRollupField_(rec, 'platform', getVal('platform'), receivedAt);

    const sessionId = getVal('session_id');
    if (sessionId) rec.sessionIds[sessionId] = true;

    const outcome = getVal('outcome');
    if (outcome === 'completed') rec.completed_count++;
    else if (outcome === 'blocked') rec.blocked_count++;
    else if (outcome === 'error') rec.error_count++;
    else if (outcome === 'scope_rejected') rec.scope_rejected_count++;

    const turnsRaw = getVal('turns');
    if (turnsRaw !== '') { rec.turnsSum += Number(turnsRaw) || 0; rec.turnsCount++; }

    const tokensRaw = getVal('tokens');
    if (tokensRaw !== '') { rec.tokensSum += Number(tokensRaw) || 0; rec.tokensCount++; }

    const durationRaw = getVal('session_duration_min');
    if (durationRaw !== '') { rec.durationSum += Number(durationRaw) || 0; rec.durationCount++; }

    const satisfaction = getVal('satisfaction');
    if (satisfaction === 'positive') rec.satisfaction_positive++;
    else if (satisfaction === 'neutral') rec.satisfaction_neutral++;
    else if (satisfaction === 'negative') rec.satisfaction_negative++;
  }
}

// `heartbeat`: already one row per install_id (upserted by
// upsertHeartbeatRow_ in Code.gs) -- read its precomputed
// first_seen/last_seen/initial_version/current_version/ping_count directly
// instead of reducing across rows. Still compared against whatever `events`
// already contributed, in case a session's own timestamp falls outside the
// heartbeat-observed range (e.g. no heartbeat fired yet that day).
function processHeartbeatRollup_(installs, sheet) {
  if (!sheet) return;
  const values = sheet.getDataRange().getValues();
  if (values.length < 2) return;

  const headers = values[0];
  const col = {};
  headers.forEach(function (h, i) { col[h] = i; });
  if (col.install_id === undefined) return;

  for (let r = 1; r < values.length; r++) {
    const row = values[r];
    const installId = String(row[col.install_id] || '');
    if (!installId) continue;

    const getVal = function (name) { return cellValue_(row, col, name); };
    const firstSeenRaw = getVal('first_seen');
    const lastSeenRaw = getVal('last_seen');
    const firstSeen = firstSeenRaw ? new Date(firstSeenRaw).getTime() : null;
    const lastSeen = lastSeenRaw ? new Date(lastSeenRaw).getTime() : null;
    const initialVersion = getVal('initial_version');
    const currentVersion = getVal('current_version');

    const rec = getRollupRecord_(installs, installId);

    if (firstSeen !== null && (rec.first_seen === null || firstSeen < rec.first_seen)) {
      rec.first_seen = firstSeen;
      if (initialVersion) rec.initial_version = initialVersion;
    }
    if (lastSeen !== null && (rec.last_seen === null || lastSeen >= rec.last_seen)) {
      rec.last_seen = lastSeen;
      if (currentVersion) rec.current_version = currentVersion;
    }

    updateRollupField_(rec, 'account_name', getVal('account_name'), lastSeen);
    updateRollupField_(rec, 'email_domain', getVal('email_domain'), lastSeen);

    rec.days_active = Number(getVal('ping_count')) || 0;
  }
}

function getRollupRecord_(installs, installId) {
  if (!installs[installId]) {
    installs[installId] = {
      install_id: installId,
      first_seen: null,
      last_seen: null,
      initial_version: '',
      current_version: '',
      account_name: '',
      email_domain: '',
      git_org: '',
      role: '',
      platform: '',
      fieldTs: {},
      sessionIds: {},
      days_active: 0,
      completed_count: 0,
      blocked_count: 0,
      error_count: 0,
      scope_rejected_count: 0,
      turnsSum: 0,
      turnsCount: 0,
      tokensSum: 0,
      tokensCount: 0,
      durationSum: 0,
      durationCount: 0,
      satisfaction_positive: 0,
      satisfaction_neutral: 0,
      satisfaction_negative: 0
    };
  }
  return installs[installId];
}

// Streaming min/max over received_at -- works regardless of row order.
// `events` rows are upserted (one row per session_id, received_at reflects
// that session's most recent update, not its session_start time), so this
// is an approximation bounded by the sheet's own storage model, not a bug
// introduced here.
function touchRollupRecord_(rec, receivedAt, skillVersion) {
  if (receivedAt == null) return;
  if (rec.first_seen === null || receivedAt < rec.first_seen) {
    rec.first_seen = receivedAt;
    if (skillVersion) rec.initial_version = skillVersion;
  }
  if (rec.last_seen === null || receivedAt >= rec.last_seen) {
    rec.last_seen = receivedAt;
    if (skillVersion) rec.current_version = skillVersion;
  }
}

// Latest non-blank value wins, tracked per field independently so a blank
// value on the most recent row doesn't blank out an earlier known value.
function updateRollupField_(rec, field, value, ts) {
  if (!value || ts == null) return;
  if (rec.fieldTs[field] === undefined || ts >= rec.fieldTs[field]) {
    rec[field] = value;
    rec.fieldTs[field] = ts;
  }
}

function writeRollup_(ss, installs) {
  let sheet = ss.getSheetByName(ROLLUP_SHEET_NAME);
  if (!sheet) sheet = ss.insertSheet(ROLLUP_SHEET_NAME);
  sheet.clearContents();

  const rows = Object.keys(installs).map(function (id) {
    const rec = installs[id];
    const outcomeSum = rec.completed_count + rec.blocked_count + rec.error_count + rec.scope_rejected_count;
    return [
      rec.install_id,
      rec.first_seen ? new Date(rec.first_seen).toISOString() : '',
      rec.last_seen ? new Date(rec.last_seen).toISOString() : '',
      rec.initial_version,
      rec.current_version,
      rec.account_name,
      rec.email_domain,
      rec.git_org,
      rec.role,
      rec.platform,
      Object.keys(rec.sessionIds).length,
      rec.days_active,
      rec.completed_count,
      rec.blocked_count,
      rec.error_count,
      rec.scope_rejected_count,
      outcomeSum ? rec.completed_count / outcomeSum : '',
      outcomeSum ? rec.error_count / outcomeSum : '',
      rec.turnsCount ? rec.turnsSum / rec.turnsCount : '',
      rec.tokensCount ? rec.tokensSum / rec.tokensCount : '',
      rec.durationCount ? rec.durationSum / rec.durationCount : '',
      rec.satisfaction_positive,
      rec.satisfaction_neutral,
      rec.satisfaction_negative
    ];
  });

  // Most recently active installs first.
  rows.sort(function (a, b) { return (b[2] || '').localeCompare(a[2] || ''); });

  sheet.getRange(1, 1, 1, ROLLUP_COLUMNS.length).setValues([ROLLUP_COLUMNS]);
  if (rows.length) {
    sheet.getRange(2, 1, rows.length, ROLLUP_COLUMNS.length).setValues(rows);
  }
}
