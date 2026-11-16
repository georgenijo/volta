#!/usr/bin/env python3
"""Summarize a scripts/startup-bench.sh run.

Reads ``milestones.ndjson`` (the app's ``startup`` log, milliseconds since
process start) and the readiness test's ``startup-samples.json`` attachment
(seconds from ``XCUIApplication.launch()``), then prints each launch and the
median and range of the measured launches. Trial zero is a warm-up.
"""

from __future__ import annotations

import json
import re
import statistics
import sys
from pathlib import Path

MILESTONES = ("appModel", "firstFrame", "shell", "vehicles", "cachedStatus", "status", "sections")
PATTERN = re.compile(r"startup milestone=(\w+) ms=(-?\d+)")


def launches(path: Path) -> list[dict[str, int]]:
    by_pid: dict[int, dict[str, int]] = {}
    order: list[int] = []
    for line in path.read_text().splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        match = PATTERN.search(event.get("eventMessage", ""))
        if not match:
            continue
        pid = event.get("processID", 0)
        if pid not in by_pid:
            by_pid[pid] = {}
            order.append(pid)
        by_pid[pid].setdefault(match.group(1), int(match.group(2)))
    return [by_pid[pid] for pid in order]


def samples(out: Path) -> list[dict]:
    for candidate in (out / "attachments").rglob("*.json"):
        try:
            data = json.loads(candidate.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, list) and data and "dashboardSeconds" in data[0]:
            return sorted(data, key=lambda item: item["trial"])
    return []


def describe(values: list[float]) -> str:
    if not values:
        return "—"
    return f"{statistics.median(values):.0f} ({min(values):.0f}–{max(values):.0f})"


def main() -> int:
    out = Path(sys.argv[1])
    runs = launches(out / "milestones.ndjson")
    tests = samples(out)
    header = ["trial", *MILESTONES, "ui.shell", "ui.dashboard"]
    print("\t".join(header))
    rows: list[dict[str, float]] = []
    for index in range(max(len(runs), len(tests))):
        row: dict[str, float] = dict(runs[index]) if index < len(runs) else {}
        if index < len(tests):
            row["ui.shell"] = tests[index]["shellSeconds"] * 1_000
            row["ui.dashboard"] = tests[index]["dashboardSeconds"] * 1_000
        rows.append(row)
        print("\t".join([str(index)] + [f"{row[key]:.0f}" if key in row else "—" for key in header[1:]]))
    measured = rows[1:]
    print("median (range), trials 1+, ms")
    summary = {key: describe([row[key] for row in measured if key in row]) for key in header[1:]}
    for key, value in summary.items():
        print(f"  {key}: {value}")
    (out / "summary.json").write_text(json.dumps({"rows": rows, "summary": summary}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
