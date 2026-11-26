#!/usr/bin/env python3
"""Builds the unit-test fixtures in Tests/Fixtures from a real export and the reference analysis.

usage: make_fixtures.py EXPORT_DIR --night-from "2026-11-26 00:50" --night-to "2026-11-26 06:05" --tz Europe/Zurich

Writes (all zlib raw-deflate, as NSData.decompressed(using: .zlib) reads them):
  night_seconds.csv.zz   unix_second,sd_g,mean_x,mean_y,mean_z  (strings exactly as recorded)
  night_heart.csv.zz     unix_start,bpm
  night_grid10.f32.zz    10 Hz x,y,z as little-endian Float32 (NaN in gaps), start in night_expected.json
  raw_excerpt.csv.zz     5 minutes of raw 50 Hz unix_time,x,y,z
  raw_excerpt_grid.f32.zz   the reference 10 Hz grid of that excerpt
  night_expected.json    what the reference analysis finds (Swift must agree)
"""
import argparse
import csv
import importlib.util
import json
import math
import zlib
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import numpy as np

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("nr", HERE / "night_reference.py")
nr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nr)


def deflate(data: bytes) -> bytes:
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("export")
    p.add_argument("--night-from", required=True)
    p.add_argument("--night-to", required=True)
    p.add_argument("--tz", default="Europe/Zurich")
    p.add_argument("--out", default=str(HERE.parent / "Tests" / "Fixtures"))
    a = p.parse_args()
    tz = ZoneInfo(a.tz)
    ts = lambda s: datetime.fromisoformat(s).replace(tzinfo=tz).timestamp()
    lo, hi = ts(a.night_from), ts(a.night_to)
    src = Path(a.export)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    # seconds, kept as the recorded strings
    rows = [r for r in csv.reader(open(src / "motion1s.csv"))][1:]
    rows = sorted((r for r in rows if lo <= float(r[0]) < hi), key=lambda r: float(r[0]))
    text = "unix_second,sd_g,mean_x,mean_y,mean_z\n" + "".join(f"{r[0]},{r[3]},{r[4]},{r[5]},{r[6]}\n" for r in rows)
    (out / "night_seconds.csv.zz").write_bytes(deflate(text.encode()))
    sec = tuple(np.array([float(r[i]) for r in rows]) for i in (0, 3, 4, 5, 6))

    hrows = [r for r in csv.reader(open(src / "hr.csv"))][1:]
    hrows = sorted((r for r in hrows if lo - 600 <= float(r[0]) < hi + 600), key=lambda r: float(r[0]))
    text = "unix_start,bpm\n" + "".join(f"{r[0]},{r[2]}\n" for r in hrows)
    (out / "night_heart.csv.zz").write_bytes(deflate(text.encode()))
    heart = (np.array([float(r[0]) for r in hrows]), np.array([float(r[2]) for r in hrows]))

    raw_rows = []
    with open(src / "raw.csv") as f:
        next(f)
        for line in f:
            t = float(line.split(",", 1)[0])
            if lo - 60 <= t < hi + 60:
                raw_rows.append(line.strip().split(","))
    raw_rows.sort(key=lambda r: float(r[0]))
    rt = np.array([float(r[0]) for r in raw_rows])
    rx, ry, rz = (np.array([float(r[i]) for r in raw_rows]) for i in (1, 2, 3))

    g0, grid = nr.resample10(rt, rx, ry, rz)
    g32 = grid.astype("<f4")
    (out / "night_grid10.f32.zz").write_bytes(deflate(g32.tobytes()))
    grid64 = g32.astype(np.float64)

    # 5-minute raw excerpt for the resampler
    e_lo = lo + 1800
    ex = [r for r in raw_rows if e_lo <= float(r[0]) < e_lo + 300]
    text = "unix_time,x,y,z\n" + "".join(",".join(r) + "\n" for r in ex)
    (out / "raw_excerpt.csv.zz").write_bytes(deflate(text.encode()))
    et = np.array([float(r[0]) for r in ex])
    eg0, eg = nr.resample10(et, *(np.array([float(r[i]) for r in ex]) for i in (1, 2, 3)))
    (out / "raw_excerpt_grid.f32.zz").write_bytes(deflate(eg.astype("<f4").tobytes()))

    def run(onset=None, wake=None):
        r = nr.analyze(sec, heart, None, [], lo, hi, onset, wake, grid=(g0, grid64))
        clean = lambda v: None if isinstance(v, float) and math.isnan(v) else v
        return {
            "onset": r["sleep"]["onset"], "wake": r["sleep"]["wake"],
            "stage": r["stage"], "breaths": [clean(v) for v in r["breaths"]],
            "cycles": [{"start": c["start"], "end": c["end"], "complete": c["complete"], "stages": c["stages"]} for c in r["cycles"]],
            "summary": {k: clean(v) for k, v in r["summary"].items()},
        }

    auto = run()
    fixed = run(ts("2026-11-26 01:11"), ts("2026-11-26 06:01"))

    # live onset and wake rules, replayed in time order
    det = nr.OnsetDetector()
    events = [(t, 0, i) for i, t in enumerate(sec[0])] + [(t, 1, i) for i, t in enumerate(heart[0])]
    events.sort()
    onset = confirmed = None
    for t, kind, i in events:
        if kind == 1:
            det.add_heart(t, heart[1][i])
        elif det.add_second(t, sec[1][i], sec[2][i], sec[3][i], sec[4][i]) is not None and onset is None:
            onset, confirmed = det.onset, t
            break

    def replay(onset_t, opens, closes):
        rule = nr.WakeRule(onset_t, opens, closes)
        for t, kind, i in events:
            if t < onset_t:
                if kind == 1:
                    rule.heart.append((t, heart[1][i]))
                continue
            res = rule.beat(t, heart[1][i]) if kind == 1 else rule.second(t, sec[1][i])
            if res:
                return {"time": t, "reason": res}
        return None

    nap = replay(onset, onset + 70 * 60, onset + 100 * 60)
    morning = replay(onset, ts("2026-11-26 06:00"), ts("2026-11-26 06:30"))

    exp = {
        "lo": lo, "hi": hi, "grid_start": g0, "grid_count": int(len(grid)),
        "excerpt_grid_start": eg0, "excerpt_grid_count": int(len(eg)),
        "auto": auto, "fixed": fixed,
        "live": {"onset": onset, "confirmed": confirmed, "nap": nap, "morning": morning},
    }
    (out / "night_expected.json").write_text(json.dumps(exp))
    f = lambda t: datetime.fromtimestamp(t, tz).strftime("%H:%M:%S")
    print("auto", f(auto["onset"]), f(auto["wake"]), [round(v) for v in auto["summary"]["stages"]],
          [(f(c["start"]), f(c["end"])) for c in auto["cycles"]])
    print("fixed", [round(v) for v in fixed["summary"]["stages"]], [(f(c["start"]), f(c["end"])) for c in fixed["cycles"]])
    print("live onset", f(onset), "confirmed", f(confirmed), "nap", f(nap["time"]), nap["reason"], "morning", f(morning["time"]), morning["reason"])
    for p_ in sorted(out.iterdir()):
        print(p_.name, p_.stat().st_size)


if __name__ == "__main__":
    main()
