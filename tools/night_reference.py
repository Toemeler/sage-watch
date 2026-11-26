#!/usr/bin/env python3
"""Reference implementation of Sage's night analysis (Shared/NightAnalysis.swift).

The Swift code in the app follows this file step by step; the unit tests compare the two on a real night. Change both
together. Plain loops on purpose: every window, threshold and tie-break is spelled out so the port stays exact.

usage: night_reference.py EXPORT_DIR_OR_ZIP [--from "2026-11-26 00:00"] [--to "2026-11-26 09:00"]
                          [--onset "2026-11-26 01:11"] [--wake "2026-11-26 06:01"] [--tz Europe/Zurich] [--json OUT]
"""
import argparse
import csv
import io
import json
import math
import zipfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import numpy as np

EPOCH = 30.0
NAN = float("nan")

# movement
MOVE_SD = 0.02            # a second counts as moving when the spread of |a| exceeds this (g)
MOVING_SECONDS = 2        # an epoch is moving with this many moving seconds ...
POSTURE_DEG = 30.0        # ... or when the wrist turned more than this against one minute earlier
AWAKE_SECONDS = 5         # seconds of movement that make an epoch "strong"
# breathing
BREATH_N = 600            # 60 s at 10 Hz
BREATH_STILL = 0.02       # per-axis spread above this: arm moving, no estimate
BREATH_BINS = [j for j in range(1, 300) if 0.12 <= j / 60.0 <= 0.6]
BREATH_PROMINENCE = 6.0
# sleep window
QUIET_FRACTION = 0.25
MERGE_GAP = 40            # epochs (20 min)
MIN_SLEEP = 120           # epochs (60 min)
# cycles: boundaries at the lightest points (troughs of the depth wave) and at the ends of REM stretches,
# chosen so that every full cycle lasts CYCLE_MIN...CYCLE_MAX minutes
TROUGH_PROMINENCE = 0.25
REM_END_SCORE = 1.0
CYCLE_MIN = 65 * 60
CYCLE_MAX = 120 * 60
LAST_MARGIN = 10 * 60     # no boundary in the last 10 minutes before waking

STAGE_AWAKE, STAGE_REM, STAGE_LIGHT, STAGE_DEEP = 0, 1, 2, 3


# ---------------------------------------------------------------- helpers (mirrored in Swift)

def nanmean(v):
    v = [x for x in v if not math.isnan(x)]
    return sum(v) / len(v) if v else NAN


def median(v):
    s = sorted(v)
    n = len(s)
    if n == 0:
        return NAN
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def std(v, ddof):
    n = len(v)
    if n - ddof <= 0:
        return NAN
    m = sum(v) / n
    return math.sqrt(sum((x - m) ** 2 for x in v) / (n - ddof))


def centered(values, half, fn, minimum):
    """fn over the valid values in [i-half, i+half] when at least `minimum` are valid, else NaN"""
    out = []
    n = len(values)
    for i in range(n):
        w = [values[j] for j in range(max(0, i - half), min(n, i + half + 1)) if not math.isnan(values[j])]
        out.append(fn(w) if len(w) >= minimum else NAN)
    return out


def zscore(values, mask):
    sel = [v for v, m in zip(values, mask) if m and not math.isnan(v)]
    if len(sel) < 2:
        return [0.0 if not math.isnan(v) else NAN for v in values]
    mu = sum(sel) / len(sel)
    sd = std(sel, 1) + 1e-9
    return [(v - mu) / sd if not math.isnan(v) else NAN for v in values]


# ---------------------------------------------------------------- breathing

def resample10(t, x, y, z):
    """raw samples -> 10 Hz grid (mean per 0.1 s bin); gaps of up to 4 bins are interpolated, longer ones stay NaN"""
    if len(t) == 0:
        return 0.0, np.zeros((0, 3))
    g0 = math.floor(t[0] * 10) / 10
    n = int(math.floor((t[-1] - g0) * 10)) + 1
    s = np.zeros((n, 3))
    c = np.zeros(n)
    idx = np.floor((np.asarray(t) - g0) * 10 + 1e-9).astype(int)
    idx = np.clip(idx, 0, n - 1)
    np.add.at(s, idx, np.stack([x, y, z], 1))
    np.add.at(c, idx, 1)
    out = np.full((n, 3), np.nan)
    ok = c > 0
    out[ok] = s[ok] / c[ok, None]
    i = 0
    while i < n:
        if ok[i]:
            i += 1
            continue
        j = i
        while j < n and not ok[j]:
            j += 1
        if i > 0 and j < n and j - i <= 4:
            for k in range(i, j):
                f = (k - (i - 1)) / (j - (i - 1))
                out[k] = out[i - 1] + (out[j] - out[i - 1]) * f
        i = j
    return g0, out


HANN = [0.5 - 0.5 * math.cos(2 * math.pi * n / (BREATH_N - 1)) for n in range(BREATH_N)]
COS = {j: [math.cos(2 * math.pi * j * n / BREATH_N) for n in range(BREATH_N)] for j in BREATH_BINS}
SIN = {j: [math.sin(2 * math.pi * j * n / BREATH_N) for n in range(BREATH_N)] for j in BREATH_BINS}


def breath_window(seg):
    """breaths per minute from 600 samples (10 Hz) of x, y, z, or NaN"""
    if any(math.isnan(v) for row in seg for v in row):
        return NAN
    best = None
    for k in range(3):
        v = [row[k] for row in seg]
        if std(v, 0) > BREATH_STILL:
            return NAN
    for k in range(3):
        v = [row[k] for row in seg]
        # least-squares line over n = 0 ... N-1
        n = BREATH_N
        mx = (n - 1) / 2
        my = sum(v) / n
        sxx = sum((i - mx) ** 2 for i in range(n))
        sxy = sum((i - mx) * (v[i] - my) for i in range(n))
        slope = sxy / sxx
        y = [(v[i] - (my + slope * (i - mx))) * HANN[i] for i in range(n)]
        p = []
        for j in BREATH_BINS:
            re = sum(y[i] * COS[j][i] for i in range(n))
            im = sum(y[i] * SIN[j][i] for i in range(n))
            p.append(re * re + im * im)
        m = max(range(len(p)), key=lambda i: (p[i], -i))     # first maximum
        prom = p[m] / (median(p) + 1e-12)
        f = BREATH_BINS[m] / 60.0
        if 0 < m < len(p) - 1:
            a, b, c = (math.log(p[m - 1] + 1e-18), math.log(p[m] + 1e-18), math.log(p[m + 1] + 1e-18))
            den = a - 2 * b + c
            if den != 0:
                f += 0.5 * (a - c) / den / 60.0
        if best is None or p[m] > best[0]:
            best = (p[m], f * 60.0, prom)
    return best[1] if best[2] > BREATH_PROMINENCE else NAN


# ---------------------------------------------------------------- the analysis

def analyze(sec, heart, raw, charging_times, lo, hi, onset=None, wake=None, grid=None):
    """sec: (t, sd, gx, gy, gz) arrays; heart: (t, bpm); raw: (t, x, y, z) or None; charging_times: list of t"""
    e0 = math.floor(lo / EPOCH) * EPOCH
    n = int(math.ceil((hi - e0) / EPOCH))
    starts = [e0 + k * EPOCH for k in range(n)]

    # motion per epoch
    nsec = [0] * n
    movs = [0] * n
    gsum = [[0.0, 0.0, 0.0] for _ in range(n)]
    st, ssd, sgx, sgy, sgz = sec
    for i in range(len(st)):
        k = int((st[i] - e0) // EPOCH)
        if 0 <= k < n:
            nsec[k] += 1
            if ssd[i] > MOVE_SD:
                movs[k] += 1
            gsum[k][0] += sgx[i]; gsum[k][1] += sgy[i]; gsum[k][2] += sgz[i]
    grav = []
    for k in range(n):
        if nsec[k] == 0:
            grav.append(None)
            continue
        g = gsum[k]
        norm = math.sqrt(g[0] ** 2 + g[1] ** 2 + g[2] ** 2)
        grav.append([v / norm for v in g] if norm > 0 else None)
    posture = [False] * n
    for k in range(2, n):
        a, b = grav[k], grav[k - 2]
        if a is not None and b is not None:
            dot = max(-1.0, min(1.0, sum(a[i] * b[i] for i in range(3))))
            posture[k] = math.degrees(math.acos(dot)) > POSTURE_DEG
    moving = [movs[k] >= MOVING_SECONDS or posture[k] for k in range(n)]

    charging = [False] * n
    for t in charging_times:
        for k in range(int((t - 60 - e0) // EPOCH), int((t + 60 - e0) // EPOCH) + 1):
            if 0 <= k < n:
                charging[k] = True

    # heart
    ht, hb = heart
    # trend: median within ±5 min; irregularity: mean |bpm - trend| within ±2.5 min (two pointers)
    trend = [NAN] * len(ht)
    a = b = 0
    for i in range(len(ht)):
        while ht[a] < ht[i] - 300:
            a += 1
        while b < len(ht) and ht[b] <= ht[i] + 300:
            b += 1
        w = hb[a:b]
        trend[i] = median(list(w)) if len(w) >= 5 else NAN
    resid = [abs(hb[i] - trend[i]) if not math.isnan(trend[i]) else NAN for i in range(len(ht))]
    irr = [NAN] * len(ht)
    a = b = 0
    for i in range(len(ht)):
        while ht[a] < ht[i] - 150:
            a += 1
        while b < len(ht) and ht[b] <= ht[i] + 150:
            b += 1
        w = [r for r in resid[a:b] if not math.isnan(r)]
        irr[i] = sum(w) / len(w) if len(w) >= 8 else NAN
    hr = [NAN] * n
    hr_irr = [NAN] * n
    hsum = [0.0] * n; hcnt = [0] * n; isum = [0.0] * n; icnt = [0] * n
    for i in range(len(ht)):
        k = int((ht[i] - e0) // EPOCH)
        if 0 <= k < n:
            hsum[k] += hb[i]; hcnt[k] += 1
            if not math.isnan(irr[i]):
                isum[k] += irr[i]; icnt[k] += 1
    for k in range(n):
        if hcnt[k]:
            hr[k] = hsum[k] / hcnt[k]
        if icnt[k]:
            hr_irr[k] = isum[k] / icnt[k]

    # breathing
    breaths = [NAN] * n
    if grid is None and raw is not None and len(raw[0]) > 0:
        grid = resample10(*raw)
    if grid is not None:
        g0, grid = grid
        for k in range(n):
            i0 = int(round((starts[k] - 15 - g0) * 10))
            if i0 < 0 or i0 + BREATH_N > len(grid):
                continue
            breaths[k] = breath_window(grid[i0:i0 + BREATH_N].tolist())
    breath_irr = centered(breaths, 5, lambda w: std(w, 1), 4)

    # sleep window
    valid = [nsec[k] >= 15 and not charging[k] for k in range(n)]
    if onset is None or wake is None:
        frac = []
        for k in range(n):
            w = [1.0 if moving[j] else 0.0 for j in range(max(0, k - 10), min(n, k + 11)) if valid[j]]
            frac.append(sum(w) / len(w) if len(w) >= 10 else NAN)
        quiet = [valid[k] and not math.isnan(frac[k]) and frac[k] < QUIET_FRACTION for k in range(n)]
        runs = []
        k = 0
        while k < n:
            if quiet[k]:
                j = k
                while j < n and quiet[j]:
                    j += 1
                if runs and k - runs[-1][1] < MERGE_GAP:
                    runs[-1][1] = j
                else:
                    runs.append([k, j])
                k = j
            else:
                k += 1
        if runs:
            s, e = max(runs, key=lambda r: (r[1] - r[0], -r[0]))
            if e - s >= MIN_SLEEP:
                onset = starts[s] if onset is None else onset
                wake = starts[e - 1] + EPOCH if wake is None else wake
    if onset is None or wake is None or wake <= onset:
        return {"sleep": None, "starts": starts, "hr": hr, "breaths": breaths, "moving": moving, "movs": movs}

    sl = [onset <= starts[k] < wake for k in range(n)]

    # stages
    fill_irr = median([hr_irr[k] for k in range(n) if sl[k] and not math.isnan(hr_irr[k])])
    irr_f = [hr_irr[k] if not math.isnan(hr_irr[k]) else fill_irr for k in range(n)]
    have_b = sum(1 for k in range(n) if sl[k] and not math.isnan(breath_irr[k])) >= 20
    if have_b:
        logb = [math.log(v) if not math.isnan(v) and v > 0 else NAN for v in breath_irr]
        fill_b = median([logb[k] for k in range(n) if sl[k] and not math.isnan(logb[k])])
        logb = [v if not math.isnan(v) else fill_b for v in logb]
        z_b_raw = zscore(logb, sl)
    else:
        z_b_raw = [0.0] * n
    z_i_raw = zscore(irr_f, sl)
    zi = centered(z_i_raw, 3, nanmean, 1)
    zb = centered(z_b_raw, 3, nanmean, 1)
    hr_s = centered(hr, 3, nanmean, 1)
    base = centered(hr, 60, median, 30)
    det = [hr_s[k] - base[k] if not (math.isnan(hr_s[k]) or math.isnan(base[k])) else NAN for k in range(n)]
    zd = [0.0 if math.isnan(v) else v for v in zscore(det, sl)]
    quiet2 = [sum(movs[max(0, k - 2):k + 3]) <= 2 for k in range(n)]
    calm4 = [sum(movs[max(0, k - 4):k + 5]) == 0 for k in range(n)]
    strong = [1 if movs[k] >= AWAKE_SECONDS else 0 for k in range(n)]

    stage = [STAGE_AWAKE] * n
    for k in range(n):
        if not sl[k]:
            continue
        s = STAGE_LIGHT
        mins = (starts[k] - onset) / 60
        deep = calm4[k] and zi[k] < -0.4 and zb[k] < 0 and zd[k] < 0.5
        rem = quiet2[k] and max(zi[k], zb[k]) > 0.35 and mins > 50 and not deep
        if deep:
            s = STAGE_DEEP
        elif rem:
            s = STAGE_REM
        if sum(strong[max(0, k - 1):k + 2]) >= 2:
            s = STAGE_AWAKE
        stage[k] = s
    filtered = stage[:]
    for k in range(n):
        if not sl[k] or stage[k] == STAGE_AWAKE:
            continue
        counts = [0, 0, 0, 0]
        for j in range(max(0, k - 3), min(n, k + 4)):
            if sl[j] and stage[j] != STAGE_AWAKE:
                counts[stage[j]] += 1
        filtered[k] = max(range(1, 4), key=lambda s: (counts[s], -s))
    stage = filtered

    # depth wave and cycles
    movf = centered([1.0 if m else 0.0 for m in moving], 5, nanmean, 1)
    z_m = zscore(movf, sl)
    raw_depth = []
    for k in range(n):
        if not sl[k]:
            raw_depth.append(NAN)
            continue
        raw_depth.append(-(z_i_raw[k] + z_b_raw[k] + z_m[k] + 0.5 * zd[k]) / 3.5)
    depth = centered(raw_depth, 10, nanmean, 6)
    ks = [k for k in range(n) if sl[k]]
    d = [depth[k] for k in ks]
    inv = [-v if not math.isnan(v) else -1e9 for v in d]
    cands = {}
    for i, prom in troughs_with_prominence(inv):
        if prom >= TROUGH_PROMINENCE:
            cands[ks[i]] = max(cands.get(ks[i], 0.0), prom)
    # the end of a dream (REM) stretch is where a cycle classically ends
    k = 0
    blocks = []
    while k < n:
        if sl[k] and stage[k] == STAGE_REM:
            j = k
            while j < n and sl[j] and stage[j] == STAGE_REM:
                j += 1
            if blocks and k - blocks[-1][1] < 10:
                blocks[-1][1] = j
            else:
                blocks.append([k, j])
            k = j
        else:
            k += 1
    for b0, b1 in blocks:
        if b1 - b0 >= 8 and b1 < n:
            cands[b1] = max(cands.get(b1, 0.0), REM_END_SCORE)
    bounds = [onset] + cycle_bounds(sorted((starts[k], sc) for k, sc in cands.items()), onset, wake) + [wake]

    cycles = []
    for a, b in zip(bounds, bounds[1:]):
        mins = {s: 0.0 for s in range(4)}
        for k in range(n):
            if sl[k] and a <= starts[k] < b:
                mins[stage[k]] += EPOCH / 60
        cycles.append({"start": a, "end": b, "minutes": (b - a) / 60, "complete": b != wake or (b - a) >= 80 * 60,
                       "stages": [mins[0], mins[1], mins[2], mins[3]]})

    stage_min = [0.0] * 4
    for k in range(n):
        if sl[k]:
            stage_min[stage[k]] += EPOCH / 60
    hs = [(ht[i], hb[i]) for i in range(len(ht)) if onset <= ht[i] < wake]
    low5, low5_at = NAN, None
    a = 0
    for i in range(len(hs)):
        while hs[a][0] < hs[i][0] - 300:
            a += 1
        w = [v for _, v in hs[a:i + 1]]
        if len(w) >= 10:
            m = median(w)
            if math.isnan(low5) or m < low5:
                low5, low5_at = m, hs[i][0]
    br = [breaths[k] for k in range(n) if sl[k] and not math.isnan(breaths[k])]
    mv_secs = [st[i] for i in range(len(st)) if onset <= st[i] < wake and ssd[i] > MOVE_SD]
    bursts = 0
    for i, t in enumerate(mv_secs):
        if i == 0 or t - mv_secs[i - 1] > 30:
            bursts += 1
    return {
        "sleep": {"onset": onset, "wake": wake},
        "starts": starts, "stage": stage, "depth": depth, "hr": hr, "breaths": breaths, "movs": movs, "moving": moving,
        "cycles": cycles,
        "summary": {
            "minutes": (wake - onset) / 60, "stages": stage_min,
            "hr_mean": sum(v for _, v in hs) / len(hs) if hs else NAN,
            "hr_min": min(v for _, v in hs) if hs else NAN,
            "hr_low5": low5, "hr_low5_at": low5_at,
            "breaths": median(br) if br else NAN,
            "bursts": bursts,
        },
    }


def troughs_with_prominence(x):
    """(index, prominence) of every local maximum of x (plateaus: their middle), prominence as in scipy"""
    n = len(x)
    out = []
    i = 1
    while i < n - 1:
        if x[i - 1] < x[i]:
            j = i
            while j + 1 < n and x[j + 1] == x[i]:
                j += 1
            if j + 1 < n and x[j + 1] < x[i]:
                p = (i + j) // 2
                lo_i, lmin = p, x[p]
                while lo_i > 0 and x[lo_i - 1] <= x[p]:
                    lo_i -= 1
                    lmin = min(lmin, x[lo_i])
                hi_i, rmin = p, x[p]
                while hi_i < n - 1 and x[hi_i + 1] <= x[p]:
                    hi_i += 1
                    rmin = min(rmin, x[hi_i])
                out.append((p, x[p] - max(lmin, rmin)))
            i = j + 1
        else:
            i += 1
    return out


def cycle_bounds(cands, onset, wake):
    """Pick boundaries from (time, score) candidates: every full cycle lasts CYCLE_MIN..CYCLE_MAX, the last part up to
    the wake at most CYCLE_MAX; maximise the summed score (ties: more boundaries, then earlier ones)."""
    cands = [(t, sc) for t, sc in cands if onset + CYCLE_MIN <= t <= wake - LAST_MARGIN]
    best = {}          # index -> (score, count, chain)
    for i, (t, sc) in enumerate(cands):
        opts = []
        if CYCLE_MIN <= t - onset <= CYCLE_MAX:
            opts.append((sc, 1, [t]))
        for j in range(i):
            tj = cands[j][0]
            if j in best and CYCLE_MIN <= t - tj <= CYCLE_MAX:
                b = best[j]
                opts.append((b[0] + sc, b[1] + 1, b[2] + [t]))
        if opts:
            best[i] = max(opts, key=lambda o: (round(o[0], 9), o[1], [-v for v in o[2]]))
    finals = [best[i] for i in best if wake - cands[i][0] <= CYCLE_MAX]
    if not finals:
        return []
    return max(finals, key=lambda o: (round(o[0], 9), o[1], [-v for v in o[2]]))[2]


# ---------------------------------------------------------------- loading

def read_csv(src, name):
    if isinstance(src, zipfile.ZipFile):
        for n in src.namelist():
            if n.endswith("/" + name) or n == name:
                return list(csv.reader(io.TextIOWrapper(src.open(n), "utf-8")))
        return None
    p = Path(src) / name
    return list(csv.reader(open(p))) if p.exists() else None


def load(path, lo, hi):
    src = zipfile.ZipFile(path) if str(path).endswith(".zip") else path
    rows = read_csv(src, "motion1s.csv")[1:]
    rows = [r for r in rows if lo - 60 <= float(r[0]) < hi + 60]
    rows.sort(key=lambda r: float(r[0]))
    sec = tuple(np.array([float(r[i]) for r in rows]) for i in (0, 3, 4, 5, 6))
    hrows = sorted(([float(r[0]), float(r[2])] for r in read_csv(src, "hr.csv")[1:] if lo - 600 <= float(r[0]) < hi + 600))
    heart = (np.array([r[0] for r in hrows]), np.array([r[1] for r in hrows]))
    raw = None
    rr = read_csv(src, "raw.csv") or read_csv(src, "raw_gyro.csv")
    if rr:
        rr = sorted(([float(r[0]), float(r[1]), float(r[2]), float(r[3])] for r in rr[1:] if lo - 60 <= float(r[0]) < hi + 60))
        a = np.array(rr)
        raw = (a[:, 0], a[:, 1], a[:, 2], a[:, 3])
    st = read_csv(src, "status.csv") or [[]]
    charging = [float(r[0]) for r in st[1:] if len(r) > 2 and r[2] in ("charging", "full")]
    return sec, heart, raw, charging


def main():
    p = argparse.ArgumentParser()
    p.add_argument("export")
    p.add_argument("--from", dest="start")
    p.add_argument("--to", dest="end")
    p.add_argument("--onset")
    p.add_argument("--wake")
    p.add_argument("--tz", default="Europe/Zurich")
    p.add_argument("--json")
    a = p.parse_args()
    tz = ZoneInfo(a.tz)
    ts = lambda s: datetime.fromisoformat(s).replace(tzinfo=tz).timestamp()
    lo, hi = ts(a.start), ts(a.end)
    sec, heart, raw, charging = load(a.export, lo, hi)
    r = analyze(sec, heart, raw, charging, lo, hi, ts(a.onset) if a.onset else None, ts(a.wake) if a.wake else None)
    fmt = lambda t: datetime.fromtimestamp(t, tz).strftime("%H:%M")
    if r["sleep"] is None:
        print("no sleep found")
    else:
        s = r["summary"]
        print(f"asleep {fmt(r['sleep']['onset'])} -> {fmt(r['sleep']['wake'])}  {s['minutes']:.0f} min")
        print("stages awake/REM/light/deep:", [round(v) for v in s["stages"]])
        for c in r["cycles"]:
            print(f"  cycle {fmt(c['start'])} -> {fmt(c['end'])}  {c['minutes']:.0f} min  complete={c['complete']}  {[round(v) for v in c['stages']]}")
        print(f"hr mean {s['hr_mean']:.1f} min {s['hr_min']} low5 {s['hr_low5']} at {fmt(s['hr_low5_at'])}  breaths {s['breaths']:.1f}  bursts {s['bursts']}")
    if a.json:
        Path(a.json).write_text(json.dumps(r, default=float))


if __name__ == "__main__":
    main()


# ---------------------------------------------------------------- live detection on the watch (Shared/SleepOnset.swift)

ONSET_WINDOW = 20         # epochs looked back over (10 min), centre lags 5 min
ONSET_CONFIRM = 20        # quiet epochs in a row before the onset counts (10 min)


class OnsetDetector:
    """Causal twin of the offline quiet rule: an epoch is quiet when fewer than QUIET_FRACTION of the epochs within
    ±10 of it are moving; ONSET_CONFIRM quiet epochs in a row (and a heart rate not above the half hour before)
    make the first of them the moment of falling asleep. While the heart has not settled the candidate moves on
    epoch by epoch: lying still with a racing heart is not dated as sleep. Feed seconds in time order."""

    def __init__(self):
        self.epoch = None
        self.nsec = self.movs = 0
        self.g = [0.0, 0.0, 0.0]
        self.hist = []        # (start, valid, moving, gravity)
        self.run_start = None
        self.run_len = 0
        self.heart = []       # (t, bpm)
        self.onset = None

    def add_heart(self, t, bpm):
        self.heart.append((t, bpm))
        cut = t - 7200
        while self.heart and self.heart[0][0] < cut:
            self.heart.pop(0)

    def add_second(self, t, sd, gx, gy, gz):
        e = math.floor(t / EPOCH) * EPOCH
        if self.epoch is None:
            self.epoch = e
        while e > self.epoch:
            self._close()
            self.epoch += EPOCH
        self.nsec += 1
        if sd > MOVE_SD:
            self.movs += 1
        self.g[0] += gx; self.g[1] += gy; self.g[2] += gz
        return self.onset

    def _close(self):
        g = None
        if self.nsec:
            norm = math.sqrt(sum(v * v for v in self.g))
            g = [v / norm for v in self.g] if norm > 0 else None
        posture = False
        if len(self.hist) >= 2 and g is not None and self.hist[-2][3] is not None:
            dot = max(-1.0, min(1.0, sum(g[i] * self.hist[-2][3][i] for i in range(3))))
            posture = math.degrees(math.acos(dot)) > POSTURE_DEG
        self.hist.append((self.epoch, self.nsec >= 15, self.movs >= MOVING_SECONDS or posture, g))
        if len(self.hist) > 60:
            self.hist.pop(0)
        self.nsec = self.movs = 0
        self.g = [0.0, 0.0, 0.0]
        if self.onset is not None or len(self.hist) < ONSET_WINDOW + 1:
            return
        window = self.hist[-(ONSET_WINDOW + 1):]
        centre = window[ONSET_WINDOW // 2]
        v = [w for w in window if w[1]]
        quiet = centre[1] and len(v) >= 10 and sum(1 for w in v if w[2]) / len(v) < QUIET_FRACTION
        if not quiet:
            self.run_start, self.run_len = None, 0
            return
        if self.run_start is None:
            self.run_start = centre[0]
        self.run_len += 1
        if self.run_len >= ONSET_CONFIRM:
            if self._heart_settled():
                self.onset = self.run_start
            else:
                # still, but the heart has not settled: if this turns into sleep, it starts later
                self.run_start += EPOCH
                self.run_len -= 1

    def _heart_settled(self):
        before = [b for t, b in self.heart if self.run_start - 1800 <= t < self.run_start]
        during = [b for t, b in self.heart if t >= self.run_start]
        if len(before) < 10 or len(during) < 10:
            return True
        return median(during) <= median(before) + 1


STIR_SECONDS = 3          # moving seconds within the last minute that count as stirring
HR_RISE = 8.0             # bpm: the 2-minute median above the sleep baseline that counts as surfacing


class WakeRule:
    """Inside [opens, closes): wake at the first stirring (STIR_SECONDS moving seconds in the last 60 s) or when the
    heart rate rises HR_RISE above its sleep baseline (median from onset+10 min to 5 min ago, >= 30 samples; recent
    = median of the last 2 minutes, >= 5 samples, checked at every heart sample); at `closes` wake regardless."""

    def __init__(self, onset, opens, closes):
        self.onset, self.opens, self.closes = onset, opens, closes
        self.moving = []      # times of moving seconds
        self.heart = []

    def second(self, t, sd):
        if sd > MOVE_SD:
            self.moving.append(t)
        while self.moving and self.moving[0] <= t - 60:
            self.moving.pop(0)
        if t >= self.closes:
            return "latest"
        if t >= self.opens and len(self.moving) >= STIR_SECONDS:
            return "stirring"
        return None

    def beat(self, t, bpm):
        self.heart.append((t, bpm))
        if t >= self.closes:
            return "latest"
        if t < self.opens:
            return None
        base = [b for u, b in self.heart if self.onset + 600 <= u < t - 300]
        recent = [b for u, b in self.heart if t - 120 <= u <= t]
        if len(base) >= 30 and len(recent) >= 5 and median(recent) >= median(base) + HR_RISE:
            return "heart"
        return None
