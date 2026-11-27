#!/usr/bin/env python3
"""Quick health check of a Sage export with position tracking: is everything being recorded, on both devices, at
the right rate, without gaps? Meant for a short export during a recording day, so a missing permission or a
stopped stream is found while it can still be fixed, not in the evening.

usage: check_export.py EXPORT_DIR
"""
import csv
import math
import sys
from pathlib import Path

import numpy as np

# stream, expected lines per second while running (None: event-driven), what it is
STREAMS = [
    ("location", None, "watch GPS"), ("phonelocation", None, "iPhone GPS"),
    ("heading", 10, "watch compass"), ("phoneheading", 10, "iPhone compass"),
    ("steps", None, "watch steps/floors"), ("phonesteps", None, "iPhone steps/floors"),
    ("pressure", None, "watch barometer"), ("phonepressure", None, "iPhone barometer"),
    ("altitude", None, "watch absolute altitude"), ("phonealtitude", None, "iPhone absolute altitude"),
]


def load(p):
    rows = []
    with open(p) as f:
        r = csv.reader(f)
        next(r, None)
        for row in r:
            try:
                rows.append([float(v) if v != "" else math.nan for v in row])
            except ValueError:
                pass
    if not rows:
        return None
    w = max(len(r) for r in rows)
    return np.array([r + [math.nan] * (w - len(r)) for r in rows])


def main(d: Path):
    ok, problems = [], []
    span = None
    for name, rate, what in STREAMS:
        p = d / f"{name}.csv"
        a = load(p) if p.exists() else None
        if a is None:
            problems.append(f"✗ {what}: missing ({name}.csv)")
            continue
        t = np.sort(a[:, 0])
        dur = t[-1] - t[0]
        span = dur if span is None else max(span, dur)
        gaps = np.diff(t)
        big = gaps[gaps > 120]
        line = f"{what}: {len(t)} lines over {dur/60:.0f} min"
        if rate:
            per_s = len(t) / max(dur, 1)
            line += f", {per_s:.1f}/s"
            if per_s < rate * 0.6:
                problems.append(f"! {what}: only {per_s:.1f} lines/s (expected ~{rate}) — throttled or paused")
        if len(big):
            note = " (normal while indoors)" if name.endswith("location") else ""
            problems.append(f"! {what}: {len(big)} gap(s) over 2 min, longest {big.max()/60:.0f} min{note}")
        if name.endswith("location"):
            acc = a[:, 4]
            good = acc[(acc > 0)]
            if len(good):
                line += f", accuracy median {np.median(good):.0f} m (best {good.min():.0f} m)"
                if np.median(good) > 50:
                    problems.append(f"! {what}: accuracy median {np.median(good):.0f} m — mostly indoors or Wi-Fi only")
            else:
                problems.append(f"✗ {what}: no valid fix")
        if name.endswith("heading"):
            h = a[:, 1]
            bad = np.mean(h < 0)
            line += f", compass valid {100 * (1 - bad):.0f} %"
            if bad > 0.5:
                problems.append(f"✗ {what}: compass mostly unavailable (heading -1) — calibrate (figure-eight) or "
                                "check that position tracking uses magnetic north")
        if name.endswith("steps"):
            line += f", {int(np.nanmax(a[:, 1]))} steps"
            if a.shape[1] > 3:
                up, down = np.nanmax(a[:, 3]) if not np.isnan(a[:, 3]).all() else 0, np.nanmax(a[:, 4]) if not np.isnan(a[:, 4]).all() else 0
                line += f", floors ↑{int(up)} ↓{int(down)}"
        if name.endswith("pressure"):
            rel = a[:, 2]
            line += f", height range {np.nanmin(rel):.1f} … {np.nanmax(rel):.1f} m"
        ok.append("✓ " + line)
    # lessons from the first real day (27 Nov): the watch's switch was off, and its barometer was timestamped in 2052
    import json, time
    try:
        segs = json.load(open(d / "segments.json"))
    except (OSError, ValueError):
        segs = []
    watch_runs = [g for g in segs if not str(g.get("segment", "")).startswith("phone-")]
    phone_runs = [g for g in segs if str(g.get("segment", "")).startswith("phone-")]
    if phone_runs and watch_runs and not any(g.get("track_position") for g in watch_runs):
        problems.append("! watch: position tracking was off in every run (Track position in the watch's long-press "
                        "menu): only the iPhone recorded your path")
    future = []
    for name in ["pressure", "phonepressure", "heading", "phoneheading", "location", "phonelocation"]:
        f = d / f"{name}.csv"
        a = load(f) if f.exists() else None
        if a is not None and np.nanmax(a[:, 0]) > time.time() + 86400:
            future.append(name)
    if future:
        problems.append("✗ timestamps in the future in " + ", ".join(future) + " (the watchOS 27 altimeter clock; "
                        "fixed in build 120, older files keep the wrong times)")
    print("\n".join(ok))
    if problems:
        print("\nTo look at:")
        print("\n".join(problems))
    else:
        print("\nEverything is being recorded.")
    return 0 if not any(p.startswith("✗") for p in problems) else 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")          # the Windows console would choke on the check marks
    sys.exit(main(Path(sys.argv[1])))
