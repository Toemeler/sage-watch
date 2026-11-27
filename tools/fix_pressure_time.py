#!/usr/bin/env python3
"""Repair the watch barometer's timestamps in an export recorded before build 120.

The altimeter on watchOS 27 reports seconds since 2001, not since boot; the app added the watch's boot time, so
every pressure line is late by (boot time - 2001-01-01) — about 26 years ("exports ending in 2052"):

    wrong = true + boot_time - 978307200          one constant per boot of the watch

The barometer runs exactly while the recorder runs, so its blocks of lines (separated by pauses) must sit inside
the watch's own motion recording (motion1s.csv, whose times are right). For each boot, the shift is the one that
puts the most pressure lines inside that coverage, found by lining a pressure block's start up with a motion block's
start; blocks that fit it (>= 90 % inside) take it, the rest (after a restart of the watch) get their own search.

usage: fix_pressure_time.py EXPORT_DIR      repairs pressure.csv in place (the original is kept as pressure.orig.csv)
"""
import csv
import shutil
import sys
import time
from pathlib import Path

import numpy as np

FUTURE = 2.0e9          # 2033: the clock bug wrote ~2.6e9 (2052); real and test data stay well below


def blocks(ts, gap=120.0):
    ts = np.sort(ts)
    cut = np.flatnonzero(np.diff(ts) > gap)
    s = np.concatenate([[0], cut + 1]); e = np.concatenate([cut, [len(ts) - 1]])
    return [(ts[a], ts[b]) for a, b in zip(s, e)]


def inside_share(a, b, sh, cover):
    """share of [a-sh, b-sh] covered by the motion blocks (a minute of slack at each end)"""
    lo, hi = a - sh, b - sh
    if hi - lo < 1:
        return 1.0 if any(c0 - 60 <= lo <= c1 + 60 for c0, c1 in cover) else 0.0
    got = sum(max(0.0, min(hi, c1 + 60) - max(lo, c0 - 60)) for c0, c1 in cover)
    return got / (hi - lo)


def phone_shift(W, P, step=5.0):
    """the shift (wrong - true) under which the watch's 60-s height changes best match the iPhone's"""
    t = np.arange(P[0, 0], P[-1, 0], step)
    # only where the iPhone itself has data (its battery may have died mid-day)
    pi = np.clip(np.searchsorted(P[:, 0], t), 1, len(P) - 1)
    t = t[np.minimum(np.abs(P[pi, 0] - t), np.abs(P[pi - 1, 0] - t)) < 30]
    if len(t) < 400:
        return None, 0.0
    ph = np.interp(t, P[:, 0], P[:, 2]); dp = ph[12:] - ph[:-12]
    dp[np.diff(t)[:len(dp)] > 2 * step] = 0          # no change across the iPhone's own gaps
    best = (None, 0.0)
    for coarse in (True, False):
        if coarse:
            cands = np.arange(W[0, 0] - t[-1], W[-1, 0] - t[0], 60.0)
        else:
            if best[0] is None:
                break
            cands = np.arange(best[0] - 90, best[0] + 90, 5.0)
        for sh in cands:
            tw = t + sh
            idx = np.clip(np.searchsorted(W[:, 0], tw), 1, len(W) - 1)
            near = np.minimum(np.abs(W[idx, 0] - tw), np.abs(W[idx - 1, 0] - tw)) < 30
            ok = near[12:] & near[:-12]
            if ok.sum() < 1000:
                continue
            wh = np.interp(tw, W[:, 0], W[:, 2]); dw = (wh[12:] - wh[:-12])[ok]; b = dp[ok]
            c = float((dw * b).sum() / np.sqrt((dw * dw).sum() * (b * b).sum() + 1e-9))
            if c > best[1]:
                best = (float(sh), c)
    return best


def main(d: Path) -> int:
    src = d / "pressure.csv"
    rows = list(csv.reader(open(src)))
    header, data = rows[0], [r for r in rows[1:] if r]
    t = np.array([float(r[0]) for r in data])
    bad = t > FUTURE
    if not bad.any():
        print("pressure.csv: all times plausible, nothing to repair")
        return 0
    cover = blocks(np.array([float(r[0]) for r in list(csv.reader(open(d / "motion1s.csv")))[1:] if r]))
    todo = blocks(t[bad])
    shift_of = {}                                  # pressure block start -> shift
    boots = 0
    # 1. where the iPhone's barometer overlaps: the shift whose watch height changes match the iPhone's (lift rides,
    #    stairs: weather drift does not disturb 60-s changes). 27 Nov: correlation 0.95, unambiguous.
    ph = d / "phonepressure.csv"
    if ph.exists():
        P = np.array([[float(x) for x in r[:3]] for r in list(csv.reader(open(ph)))[1:] if r])
        W = np.array([[float(x) for x in r[:3]] for r in data])[bad]
        W = W[np.argsort(W[:, 0])]
        sh, c = phone_shift(W, P)
        if sh is not None and c > 0.8:
            fit = [(a, b) for a, b in todo if inside_share(a, b, sh, cover) >= 0.9]
            if fit:
                boots += 1
                for a, b in fit:
                    shift_of[a] = (sh, b)
                todo = [x for x in todo if x not in fit]
                print(f"iPhone barometer match: correlation {c:.2f}, {len(fit)} block(s)")
    # 2. the rest: line blocks up with the watch's own motion recording
    while todo:
        best = (None, -1.0)
        for a, _ in todo:
            for c0, _ in cover:
                sh = a - c0
                score = sum((b - a2 + 1) for a2, b in todo if inside_share(a2, b, sh, cover) >= 0.9)
                if score > best[1]:
                    best = (sh, score)
        sh = best[0]
        fit = [(a, b) for a, b in todo if inside_share(a, b, sh, cover) >= 0.9]
        if not fit:
            break
        boots += 1
        for a, b in fit:
            shift_of[a] = (sh, b)
        todo = [x for x in todo if x not in fit]
    starts = sorted(shift_of)
    out, moved, left = [], 0, 0
    for r, tt, isbad in zip(data, t, bad):
        if not isbad:
            out.append(r); continue
        k = int(np.searchsorted(starts, tt, side="right")) - 1
        if k < 0 or tt > shift_of[starts[k]][1] + 1:
            left += 1; continue
        out.append([f"{tt - shift_of[starts[k]][0]:.3f}"] + r[1:]); moved += 1
    out.sort(key=lambda r: float(r[0]))
    shutil.copy(src, d / "pressure.orig.csv")
    with open(src, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(out)
    print(f"pressure.csv: {moved} lines moved back ({boots} boot(s) of the watch), {left} left out "
          f"(fit no recording); original kept as pressure.orig.csv")
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main(Path(sys.argv[1])))
