#!/usr/bin/env python3
"""Deterministic identity reuse/backfill for ThemeMate telemetry workbook.

Modes:
- dry-run: produce summary + preview/conflict/unresolved artifacts
- apply: write backfilled copy of workbook (never edits source in place)
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import xml.etree.ElementTree as ET

NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
EMAIL_DOMAIN_PATTERN = re.compile(
    r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"
)
SENTINELS = {
    "account_name": "unknown-operator",
    "email_domain": "unknown.local",
}


@dataclass
class WorkbookSheet:
    name: str
    target: str
    root: ET.Element


def qn(local: str) -> str:
    return f"{{{NS_MAIN}}}{local}"


def col_to_idx(ref: str) -> int:
    letters = "".join(ch for ch in ref if ch.isalpha())
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch.upper()) - 64)
    return n - 1


def idx_to_col(idx: int) -> str:
    idx += 1
    chars = []
    while idx:
        idx, rem = divmod(idx - 1, 26)
        chars.append(chr(65 + rem))
    return "".join(reversed(chars))


def load_shared_strings(zf: zipfile.ZipFile) -> Tuple[List[str], Dict[str, int], ET.Element]:
    path = "xl/sharedStrings.xml"
    if path in zf.namelist():
        root = ET.fromstring(zf.read(path))
    else:
        root = ET.Element(qn("sst"), {"count": "0", "uniqueCount": "0"})
    strings: List[str] = []
    index: Dict[str, int] = {}
    for si in root.findall(qn("si")):
        value = "".join((t.text or "") for t in si.iter(qn("t")))
        index[value] = len(strings)
        strings.append(value)
    return strings, index, root


def ensure_sst_idx(value: str, sst_list: List[str], sst_index: Dict[str, int], sst_root: ET.Element) -> int:
    if value in sst_index:
        return sst_index[value]
    idx = len(sst_list)
    sst_index[value] = idx
    sst_list.append(value)

    si = ET.SubElement(sst_root, qn("si"))
    t = ET.SubElement(si, qn("t"))
    t.text = value
    sst_root.set("uniqueCount", str(len(sst_list)))
    sst_root.set("count", str(len(sst_list)))
    return idx


def sheet_map(zf: zipfile.ZipFile) -> Dict[str, str]:
    wb = ET.fromstring(zf.read("xl/workbook.xml"))
    rels = ET.fromstring(zf.read("xl/_rels/workbook.xml.rels"))
    rid_to_target = {
        rel.attrib["Id"]: rel.attrib["Target"]
        for rel in rels
    }
    out: Dict[str, str] = {}
    sheets = wb.find(qn("sheets"))
    if sheets is None:
        return out
    for s in sheets:
        name = s.attrib.get("name", "")
        rid = s.attrib.get(f"{{{NS_REL}}}id", "")
        target = rid_to_target.get(rid, "")
        if target:
            out[name] = f"xl/{target}"
    return out


def parse_sheet_rows(root: ET.Element, sst: List[str]) -> List[List[str]]:
    sheet_data = root.find(qn("sheetData"))
    if sheet_data is None:
        return []
    rows: List[List[str]] = []
    for row in sheet_data.findall(qn("row")):
        values: List[Tuple[int, str]] = []
        for c in row.findall(qn("c")):
            ref = c.attrib.get("r", "A1")
            idx = col_to_idx(ref)
            t = c.attrib.get("t")
            v = c.find(qn("v"))
            txt = ""
            if v is not None and v.text is not None:
                if t == "s":
                    try:
                        txt = sst[int(v.text)]
                    except Exception:
                        txt = v.text
                else:
                    txt = v.text
            values.append((idx, txt))
        if values:
            max_idx = max(i for i, _ in values)
            arr = [""] * (max_idx + 1)
            for i, txt in values:
                arr[i] = txt
            rows.append(arr)
    return rows


def get_cell(row: List[str], idx: int) -> str:
    if idx < 0 or idx >= len(row):
        return ""
    return (row[idx] or "").strip()


def normalize_value(key: str, value: str) -> str:
    value = " ".join((value or "").strip().split())
    if not value:
        return ""
    if key == "account_name":
        if value.lower() == "skip":
            return ""
        if "@" in value or re.search(r"\d{7,}", value):
            return ""
        return value
    if key == "email_domain":
        value = value.lower()
        if "@" in value or not EMAIL_DOMAIN_PATTERN.match(value):
            return ""
        return value
    return value


def resolve_field(
    install_id: str,
    key: str,
    hb_map: Dict[str, Dict[str, str]],
    rollup_map: Dict[str, Dict[str, str]],
    allow_sentinels: bool,
) -> Tuple[str, str, Optional[List[str]]]:
    candidates: List[Tuple[str, str]] = []

    hb_val = normalize_value(key, hb_map.get(install_id, {}).get(key, ""))
    if hb_val:
        candidates.append(("heartbeat", hb_val))

    ru_val = normalize_value(key, rollup_map.get(install_id, {}).get(key, ""))
    if ru_val:
        candidates.append(("install_rollup", ru_val))

    unique_vals = sorted({val for _, val in candidates})
    if not unique_vals:
        if allow_sentinels:
            return SENTINELS[key], "sentinel", None
        return "", "", None

    if len(unique_vals) == 1:
        source = next(src for src, val in candidates if val == unique_vals[0])
        return unique_vals[0], source, None

    # Conflict: prefer heartbeat if present and non-sentinel.
    if hb_val and hb_val not in SENTINELS.values():
        return hb_val, "heartbeat_preferred", unique_vals

    return "", "", unique_vals


def row_to_dict(headers: List[str], row: List[str]) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for i, h in enumerate(headers):
        out[h] = get_cell(row, i)
    return out


def set_sheet_string_cell(
    ws_root: ET.Element,
    row_num: int,
    col_idx: int,
    value: str,
    sst_list: List[str],
    sst_index: Dict[str, int],
    sst_root: ET.Element,
) -> None:
    sheet_data = ws_root.find(qn("sheetData"))
    if sheet_data is None:
        raise RuntimeError("sheetData missing in worksheet")

    target_row = None
    for row_elem in sheet_data.findall(qn("row")):
        if int(row_elem.attrib.get("r", "0")) == row_num:
            target_row = row_elem
            break
    if target_row is None:
        target_row = ET.SubElement(sheet_data, qn("row"), {"r": str(row_num)})

    ref = f"{idx_to_col(col_idx)}{row_num}"
    target_cell = None
    for c in target_row.findall(qn("c")):
        if c.attrib.get("r") == ref:
            target_cell = c
            break
    if target_cell is None:
        target_cell = ET.SubElement(target_row, qn("c"), {"r": ref, "t": "s"})

    target_cell.set("t", "s")
    v = target_cell.find(qn("v"))
    if v is None:
        v = ET.SubElement(target_cell, qn("v"))

    v.text = str(ensure_sst_idx(value, sst_list, sst_index, sst_root))


def write_outputs(
    out_dir: Path,
    summary: Dict[str, object],
    preview: List[Dict[str, str]],
    conflicts: List[Dict[str, str]],
    unresolved: List[Dict[str, str]],
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    (out_dir / "backfill-summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    def write_csv(path: Path, rows: List[Dict[str, str]], headers: List[str]) -> None:
        with path.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=headers)
            w.writeheader()
            for row in rows:
                w.writerow(row)

    write_csv(
        out_dir / "backfill-preview.csv",
        preview,
        [
            "row_number",
            "install_id",
            "session_id",
            "account_name_old",
            "account_name_new",
            "account_name_source",
            "email_domain_old",
            "email_domain_new",
            "email_domain_source",
        ],
    )

    write_csv(
        out_dir / "backfill-conflicts.csv",
        conflicts,
        ["install_id", "field", "candidates", "resolution"],
    )

    write_csv(
        out_dir / "backfill-unresolved.csv",
        unresolved,
        ["row_number", "install_id", "session_id", "field", "reason"],
    )


def run_backfill(xlsx: Path, out_dir: Path, mode: str, allow_sentinels: bool) -> Dict[str, object]:
    if not xlsx.exists():
        raise FileNotFoundError(f"Workbook not found: {xlsx}")

    with zipfile.ZipFile(xlsx) as zf:
        sheets = sheet_map(zf)
        required = ["events", "heartbeat", "install_rollup"]
        missing = [name for name in required if name not in sheets]
        if missing:
            raise RuntimeError(f"Missing required sheet(s): {', '.join(missing)}")

        sst_list, sst_index, sst_root = load_shared_strings(zf)

        events_root = ET.fromstring(zf.read(sheets["events"]))
        hb_root = ET.fromstring(zf.read(sheets["heartbeat"]))
        rollup_root = ET.fromstring(zf.read(sheets["install_rollup"]))

        events_rows = parse_sheet_rows(events_root, sst_list)
        hb_rows = parse_sheet_rows(hb_root, sst_list)
        rollup_rows = parse_sheet_rows(rollup_root, sst_list)

    if not events_rows:
        raise RuntimeError("events sheet is empty")

    e_headers = events_rows[0]
    h_headers = hb_rows[0] if hb_rows else []
    r_headers = rollup_rows[0] if rollup_rows else []

    for needed in ["install_id", "account_name", "email_domain", "session_id"]:
        if needed not in e_headers:
            raise RuntimeError(f"events missing required column: {needed}")

    hb_map = {
        row_to_dict(h_headers, row).get("install_id", ""): row_to_dict(h_headers, row)
        for row in hb_rows[1:]
        if row_to_dict(h_headers, row).get("install_id", "")
    }
    rollup_map = {
        row_to_dict(r_headers, row).get("install_id", ""): row_to_dict(r_headers, row)
        for row in rollup_rows[1:]
        if row_to_dict(r_headers, row).get("install_id", "")
    }

    idx_install = e_headers.index("install_id")
    idx_session = e_headers.index("session_id")
    idx_acc = e_headers.index("account_name")
    idx_dom = e_headers.index("email_domain")

    summary = {
        "mode": mode,
        "rows_scanned": len(events_rows) - 1,
        "rows_eligible": 0,
        "rows_fillable_account": 0,
        "rows_fillable_domain": 0,
        "rows_updated_account": 0,
        "rows_updated_domain": 0,
        "rows_unresolved": 0,
        "rows_conflict": 0,
        "rows_skipped_no_install_id": 0,
        "rows_skipped_nonblank": 0,
    }

    preview: List[Dict[str, str]] = []
    conflicts: List[Dict[str, str]] = []
    unresolved: List[Dict[str, str]] = []
    updates: List[Dict[str, object]] = []

    for row_num, row in enumerate(events_rows[1:], start=2):
        install_id = get_cell(row, idx_install)
        session_id = get_cell(row, idx_session)
        old_acc = normalize_value("account_name", get_cell(row, idx_acc))
        old_dom = normalize_value("email_domain", get_cell(row, idx_dom))

        need_acc = not old_acc
        need_dom = not old_dom
        if not need_acc and not need_dom:
            summary["rows_skipped_nonblank"] += 1
            continue

        if not install_id:
            summary["rows_skipped_no_install_id"] += 1
            if need_acc:
                unresolved.append({
                    "row_number": str(row_num),
                    "install_id": "",
                    "session_id": session_id,
                    "field": "account_name",
                    "reason": "missing_install_id",
                })
            if need_dom:
                unresolved.append({
                    "row_number": str(row_num),
                    "install_id": "",
                    "session_id": session_id,
                    "field": "email_domain",
                    "reason": "missing_install_id",
                })
            continue

        summary["rows_eligible"] += 1
        new_acc = ""
        new_dom = ""
        src_acc = ""
        src_dom = ""

        if need_acc:
            new_acc, src_acc, conflict_vals = resolve_field(
                install_id, "account_name", hb_map, rollup_map, allow_sentinels
            )
            if conflict_vals and not new_acc:
                summary["rows_conflict"] += 1
                conflicts.append({
                    "install_id": install_id,
                    "field": "account_name",
                    "candidates": " | ".join(conflict_vals),
                    "resolution": "unresolved",
                })
            elif new_acc:
                summary["rows_fillable_account"] += 1
            else:
                summary["rows_unresolved"] += 1
                unresolved.append({
                    "row_number": str(row_num),
                    "install_id": install_id,
                    "session_id": session_id,
                    "field": "account_name",
                    "reason": "no_deterministic_source",
                })

        if need_dom:
            new_dom, src_dom, conflict_vals = resolve_field(
                install_id, "email_domain", hb_map, rollup_map, allow_sentinels
            )
            if conflict_vals and not new_dom:
                summary["rows_conflict"] += 1
                conflicts.append({
                    "install_id": install_id,
                    "field": "email_domain",
                    "candidates": " | ".join(conflict_vals),
                    "resolution": "unresolved",
                })
            elif new_dom:
                summary["rows_fillable_domain"] += 1
            else:
                summary["rows_unresolved"] += 1
                unresolved.append({
                    "row_number": str(row_num),
                    "install_id": install_id,
                    "session_id": session_id,
                    "field": "email_domain",
                    "reason": "no_deterministic_source",
                })

        if (need_acc and new_acc) or (need_dom and new_dom):
            updates.append(
                {
                    "row_number": row_num,
                    "install_id": install_id,
                    "session_id": session_id,
                    "account_name_old": old_acc,
                    "account_name_new": new_acc,
                    "account_name_source": src_acc,
                    "email_domain_old": old_dom,
                    "email_domain_new": new_dom,
                    "email_domain_source": src_dom,
                }
            )
            preview.append({k: str(v) for k, v in updates[-1].items()})

    write_outputs(out_dir, summary, preview, conflicts, unresolved)

    if mode == "dry-run":
        return summary

    # Apply writes into copied workbook.
    out_xlsx = out_dir / "ThemeMate Telemetry.backfilled.xlsx"
    shutil.copy2(xlsx, out_xlsx)

    with zipfile.ZipFile(out_xlsx) as in_zip:
        with zipfile.ZipFile(out_xlsx.with_suffix(".tmp.xlsx"), "w", compression=zipfile.ZIP_DEFLATED) as out_zip:
            sst_list_apply, sst_index_apply, sst_root_apply = load_shared_strings(in_zip)
            events_root_apply = ET.fromstring(in_zip.read(sheet_map(in_zip)["events"]))

            for upd in updates:
                row_num = int(upd["row_number"])
                if upd["account_name_new"]:
                    set_sheet_string_cell(
                        events_root_apply,
                        row_num,
                        idx_acc,
                        str(upd["account_name_new"]),
                        sst_list_apply,
                        sst_index_apply,
                        sst_root_apply,
                    )
                    summary["rows_updated_account"] += 1
                if upd["email_domain_new"]:
                    set_sheet_string_cell(
                        events_root_apply,
                        row_num,
                        idx_dom,
                        str(upd["email_domain_new"]),
                        sst_list_apply,
                        sst_index_apply,
                        sst_root_apply,
                    )
                    summary["rows_updated_domain"] += 1

            events_target = sheet_map(in_zip)["events"]
            for item in in_zip.infolist():
                data = in_zip.read(item.filename)
                if item.filename == events_target:
                    data = ET.tostring(events_root_apply, encoding="utf-8", xml_declaration=True)
                elif item.filename == "xl/sharedStrings.xml":
                    data = ET.tostring(sst_root_apply, encoding="utf-8", xml_declaration=True)
                out_zip.writestr(item, data)

    out_xlsx.with_suffix(".tmp.xlsx").replace(out_xlsx)
    (out_dir / "backfill-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="ThemeMate telemetry identity backfill")
    parser.add_argument("--xlsx", required=True, help="Path to telemetry workbook")
    parser.add_argument("--mode", choices=["dry-run", "apply"], default="dry-run")
    parser.add_argument(
        "--output-dir",
        default="telemetry/backfill-output",
        help="Directory for summary and report artifacts",
    )
    parser.add_argument(
        "--allow-sentinels",
        action="store_true",
        help="Allow sentinel values when deterministic sources are missing",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    summary = run_backfill(
        xlsx=Path(args.xlsx),
        out_dir=Path(args.output_dir),
        mode=args.mode,
        allow_sentinels=args.allow_sentinels,
    )
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
