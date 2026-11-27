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
        kinds = [(c["from"], c["to"], c["by"]) for c in s["floor_change_list"]]
        check("indoor: stairs vs lift", kinds == [(0, 2, "stairs"), (2, 1, "stairs"), (1, 0, "lift")], str(kinds))

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

        # the iPhone dies halfway (27 Nov): the watch's barometer (absolute pressure; its relative altitude restarts
        # at 0 with every run) carries the floors on; a 50 m descent at the end is travel, not floors
        died = tmp / "died"; died.mkdir()
        rows = [l.split(",") for l in (indoor / "phonepressure.csv").read_text().splitlines()[1:]]
        tt = np.array([float(r[0]) for r in rows]); rel = np.array([float(r[2]) for r in rows])
        cut = tt[0] + 0.55 * (tt[-1] - tt[0])
        for f in ("phonelocation.csv", "phonesteps.csv"):
            (died / f).write_text((indoor / f).read_text())
        lines = (indoor / "phonepressure.csv").read_text().splitlines(True)
        (died / "phonepressure.csv").write_text(lines[0] + "".join(l for l in lines[1:] if float(l.split(",")[0]) < cut))
        h = 500 + rel
        tail = tt > tt[-1] - 300
        h[tail] -= np.linspace(0, 50, tail.sum())              # 50 m down in the last 5 min
        kpa = 101.325 * (1 - h / 44330.0) ** (1 / 0.1903)
        with open(died / "pressure.csv", "w") as f:
            f.write("unix_time,pressure_kpa,relative_altitude_m\n")
            run0 = 0
            for k in range(len(tt)):
                if k % 1800 == 0:
                    run0 = h[k]                                     # a new recording run: relative restarts at 0
                f.write(f"{tt[k]:.3f},{kpa[k]:.4f},{h[k] - run0:.2f}\n")
        s, _ = track(died)
        kinds = [(c["from"], c["to"], c["by"]) for c in s["floor_change_list"]]
        check("iPhone dies: floors from the watch", kinds == [(0, 2, "stairs"), (2, 1, "stairs"), (1, 0, "lift")] and
              s["height_from_watch_min"] > 30, f'{kinds}, {s["height_from_watch_min"]} min from the watch')
        trav = s.get("height_changes_not_floors", [])
        check("iPhone dies: 50 m is travel", len(trav) == 1 and abs(trav[0]["metres"] + 50) <= 6, str(trav))

        # fix_pressure_time.py: barometer lines written ~26 years ahead come back to their true time
        fx = tmp / "fix"; fx.mkdir()
        true_t = np.arange(1_796_000_000, 1_796_000_000 + 7200, 2.5)
        true_t = true_t[(true_t < 1_796_002_000) | (true_t > 1_796_003_000)]   # two runs with a pause
        with open(fx / "motion1s.csv", "w") as f:
            f.write("unix_second,samples\n")
            for x in np.unique(np.floor(true_t)):
                f.write(f"{x:.0f},50\n")
        boot = 1_795_990_000.0
        with open(fx / "pressure.csv", "w") as f:
            f.write("unix_time,pressure_kpa,relative_altitude_m\n")
            for x in true_t:
                f.write(f"{x + boot - 978307200:.3f},95.0000,0.00\n")
        run(HERE / "fix_pressure_time.py", fx)
        back = np.array([float(l.split(",")[0]) for l in (fx / "pressure.csv").read_text().splitlines()[1:]])
        err = np.abs(np.sort(back) - true_t).max() if len(back) == len(true_t) else float("inf")
        check("fix pressure times", err < 3, f"max error {err:.1f} s over {len(back)} lines")

    print("\nall pass" if not fails else f"\n{len(fails)} failed: {', '.join(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
