#!/usr/bin/env python3
"""Compute identity and key telemetry completeness metrics for workbook sheets."""

from __future__ import annotations

import argparse
import json
import zipfile
from pathlib import Path
from typing import Dict, List, Tuple
import xml.etree.ElementTree as ET

NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"


def qn(local: str) -> str:
    return f"{{{NS_MAIN}}}{local}"


def col_to_idx(ref: str) -> int:
    letters = "".join(ch for ch in ref if ch.isalpha())
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch.upper()) - 64)
    return n - 1


def load_shared_strings(zf: zipfile.ZipFile) -> List[str]:
    path = "xl/sharedStrings.xml"
    if path not in zf.namelist():
        return []
    root = ET.fromstring(zf.read(path))
    out: List[str] = []
    for si in root.findall(qn("si")):
        out.append("".join((t.text or "") for t in si.iter(qn("t"))))
    return out


def sheet_map(zf: zipfile.ZipFile) -> Dict[str, str]:
    wb = ET.fromstring(zf.read("xl/workbook.xml"))
    rels = ET.fromstring(zf.read("xl/_rels/workbook.xml.rels"))
    rid_to_target = {r.attrib["Id"]: r.attrib["Target"] for r in rels}
    out: Dict[str, str] = {}
    sheets = wb.find(qn("sheets"))
    if sheets is None:
        return out
    for s in sheets:
        rid = s.attrib.get(f"{{{NS_REL}}}id", "")
        if rid in rid_to_target:
            out[s.attrib.get("name", "")] = f"xl/{rid_to_target[rid]}"
    return out


def parse_sheet_rows(zf: zipfile.ZipFile, path: str, sst: List[str]) -> List[List[str]]:
    root = ET.fromstring(zf.read(path))
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


def missing_report(rows: List[List[str]], cols: List[str]) -> Dict[str, Dict[str, float]]:
    if not rows:
        return {}
    headers = [h.strip() for h in rows[0]]
    idx_map = {h: i for i, h in enumerate(headers)}
    body = rows[1:]
    total = len(body)
    out: Dict[str, Dict[str, float]] = {}
    for key in cols:
        if key not in idx_map:
            out[key] = {"missing": -1, "total": total, "pct": -1.0}
            continue
        miss = sum(1 for row in body if not get_cell(row, idx_map[key]))
        pct = (miss / total * 100.0) if total else 0.0
        out[key] = {"missing": miss, "total": total, "pct": round(pct, 1)}
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description="Telemetry workbook completeness metrics")
    parser.add_argument("--xlsx", required=True, help="Path to workbook")
    args = parser.parse_args()

    wb_path = Path(args.xlsx)
    with zipfile.ZipFile(wb_path) as zf:
        sst = load_shared_strings(zf)
        smap = sheet_map(zf)

        if "events" not in smap or "heartbeat" not in smap:
            raise RuntimeError("Workbook must include events and heartbeat sheets")

        events_rows = parse_sheet_rows(zf, smap["events"], sst)
        hb_rows = parse_sheet_rows(zf, smap["heartbeat"], sst)

    report = {
        "workbook": str(wb_path),
        "events_rows": max(0, len(events_rows) - 1),
        "heartbeat_rows": max(0, len(hb_rows) - 1),
        "events": missing_report(
            events_rows,
            [
                "role",
                "mode",
                "platform",
                "outcome",
                "store_domain",
                "session_id",
                "account_name",
                "email_domain",
                "summary",
            ],
        ),
        "heartbeat": missing_report(
            hb_rows,
            ["email_domain", "account_name"],
        ),
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
