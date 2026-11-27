#!/usr/bin/env python3
"""Regression test for track3d.py: builds every synthetic test day and checks the results against limits.
Run after any change to track3d.py:  python tools/test_track3d.py   (exit code 0 = all pass)"""
import csv
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
PY = sys.executable


def run(*args):
    return subprocess.run([PY, *map(str, args)], capture_output=True, text=True, check=True).stdout


def track(d):
    s = json.loads(run(HERE / "track3d.py", d, "--html"))
    rows = list(csv.DictReader(open(d / "track" / "track.csv")))
    return s, {int(float(r["unix_time"])): r for r in rows}


def horiz_errors(d, est):
    tr = np.load(d / "truth.npy")
    ex = np.array([[float(est[int(t)]["x_m"]), float(est[int(t)]["y_m"])] for t in tr[:, 0] if int(t) in est])
    true = tr[:len(ex)]
    out = true[:, 4] == 0
    off = np.mean(ex[out] - true[out, 1:3], 0)
    e = np.hypot(*(ex - off - true[:, 1:3]).T)
    return np.median(e[out]), np.median(e[~out])


def floor_right(d, est, truth_floor):
    tr = np.load(d / "truth.npy")
    e = np.array([float(est.get(int(t), {}).get("floor", "nan") or "nan") for t in tr[:, 0]])
    ok = ~np.isnan(e)
    return np.mean(e[ok] == truth_floor(tr)[ok])


def main():
    fails = []
    def check(name, cond, detail):
        print(("PASS " if cond else "FAIL ") + f"{name}: {detail}")
        if not cond:
            fails.append(name)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        day, re_, indoor = tmp / "day", tmp / "repocket", tmp / "indoor"
        run(HERE / "synth_track.py", day); run(HERE / "synth_track.py", re_, "--repocket"); run(HERE / "synth_indoor.py", indoor)

        s, est = track(day)
        o, i = horiz_errors(day, est)
        check("day: floors", s["floor_changes"] == 4, f'{s["floor_changes"]} changes (4)')
        check("day: outdoors", o < 2, f"{o:.1f} m median (< 2)")
        check("day: indoors", i < 8, f"{i:.1f} m median (< 8)")
        check("day: heading offset", abs(s["heading_offset_deg"] - 35) < 5, f'{s["heading_offset_deg"]:.1f} deg (35)')
        fr = floor_right(day, est, lambda tr: np.round((tr[:, 3] - 420) / 3.0))
        check("day: floor right", fr > 0.9, f"{fr*100:.0f} % (> 90 %)")

        s, est = track(re_)
        o, i = horiz_errors(re_, est)
        offs = [p["offset_deg"] for p in s["pocket_periods"]]
        check("repocket: periods", len(offs) == 2 and abs(offs[0] - 35) < 5 and abs(offs[1] - 110) < 5, f"{offs} (35, 110)")
        check("repocket: indoors", i < 8, f"{i:.1f} m median (< 8)")

        s, est = track(indoor)
        check("indoor drift: floors", s["floor_changes"] == 4, f'{s["floor_changes"]} changes (4, despite 7.9 m drift)')
        fr = floor_right(indoor, est, lambda tr: tr[:, 1])
        check("indoor drift: floor right", fr > 0.95, f"{fr*100:.0f} % (> 95 %)")

        # derived cases from the normal day
        def derived(name, files):
            d = tmp / name; d.mkdir()
            for src, dst, keep in files:
                lines = (day / src).read_text().splitlines(True)
                (d / dst).write_text("".join(l for k, l in enumerate(lines) if k == 0 or keep(l)))
            return d
        gap = derived("gap", [(f, f, lambda l: not (1796000400 < float(l.split(",")[0]) < 1796000900))
                              for f in ("phonelocation.csv", "phoneheading.csv", "phonesteps.csv", "phonepressure.csv")])
        s, _ = track(gap)
        check("gap: marked", 6 < s["gap_minutes"] < 9, f'{s["gap_minutes"]:.1f} min (8.3 true)')
        check("gap: floors", s["floor_changes"] == 4, f'{s["floor_changes"]} changes (4)')
        nogps = derived("nogps", [(f, f, lambda l: True) for f in ("phoneheading.csv", "phonesteps.csv", "phonepressure.csv")])
        s, _ = track(nogps)
        check("no GPS: warns", any("rotated" in w for w in s["warnings"]) and any("relative" in w for w in s["warnings"]),
              f'{len(s["warnings"])} warnings')
        watch = derived("watch", [(f, f.replace("phone", ""), lambda l: True)
                                  for f in ("phonelocation.csv", "phoneheading.csv", "phonesteps.csv", "phonepressure.csv")])
        s, _ = track(watch)
        check("watch only: runs", s["floor_changes"] == 4 and s["steps_from"] == "steps", f'{s["floor_changes"]} changes, steps from {s["steps_from"]}')

    print("\nall pass" if not fails else f"\n{len(fails)} failed: {', '.join(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
