#!/usr/bin/env python3
"""Turns a Sage export (watch + iPhone with "Track position" on) into one 3D path for the day.

usage: track3d.py EXPORT_DIR [--out OUT_DIR]

Writes OUT_DIR/track.csv (1 s: time, lat, lon, altitude, floor, horizontal/vertical accuracy, source),
OUT_DIR/track.geojson, and prints a summary (distance, floors, time per floor, time outdoors/indoors).

How each dimension is estimated, best source first:
  height   barometer (iPhone's, else the watch's): relative changes to ~10 cm; its level and its slow weather drift
           are pinned to GPS / absolute-altitude readings with a 30-minute low-pass. Floors = height levels ~3 m apart.
  outdoors GPS fixes (both devices; per second the better one), weighted by their own reported accuracy
  indoors  pedestrian dead reckoning: distance per second from Apple's step counter (iPhone's when it is walking,
           else the watch's), direction from the compass heading. A phone in a pocket does not point where you walk:
           the offset between device heading and walking direction is learned from GPS course while walking outside.
  fusion   a 2D Kalman filter forward plus an RTS smoother backward, so indoor drift is pulled onto the next GPS
           fix when you come out again. Every second gets an honest accuracy estimate.
"""
import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np

R_EARTH = 6_371_000.0
FLOOR_M = 3.0


# ------------------------------------------------------------------ loading

def load(path, cols):
    """numeric columns of a CSV (header skipped, blank -> nan), sorted by time, duplicate times dropped"""
    if not path.exists():
        return None
    rows = []
    with open(path) as f:
        r = csv.reader(f)
        next(r, None)
        for row in r:
            try:
                rows.append([float(row[i]) if i < len(row) and row[i] != "" else math.nan for i in cols])
            except ValueError:
                continue
    if not rows:
        return None
    a = np.array(rows)
    a = a[np.argsort(a[:, 0], kind="stable")]
    _, keep = np.unique(a[:, 0], return_index=True)
    return a[keep]


def pick(d, *names):
    for n in names:
        p = d / f"{n}.csv"
        if p.exists():
            return p, n
    return None, None


# ------------------------------------------------------------------ helpers

def circ_mean(deg, w=None):
    r = np.radians(deg)
    w = np.ones_like(r) if w is None else w
    return math.degrees(math.atan2((np.sin(r) * w).sum(), (np.cos(r) * w).sum())) % 360


def lowpass(t, v, window):
    """centred moving average over `window` seconds (on an even 1 s grid)"""
    # cumulative sums with clipped windows: correct at the edges and for series shorter than the window
    half = max(1, int(window)) // 2
    ok = ~np.isnan(v)
    cs = np.concatenate([[0.0], np.cumsum(np.where(ok, v, 0.0))])
    cc = np.concatenate([[0.0], np.cumsum(ok.astype(float))])
    i = np.arange(len(v))
    lo, hi = np.clip(i - half, 0, len(v)), np.clip(i + half + 1, 0, len(v))
    num, den = cs[hi] - cs[lo], cc[hi] - cc[lo]
    return np.where(den > 0, num / np.maximum(den, 1e-9), np.nan)


def interp(t, src_t, src_v):
    if src_t is None or len(src_t) < 2:
        return np.full(len(t), np.nan)
    out = np.interp(t, src_t, src_v, left=np.nan, right=np.nan)
    # no interpolation across gaps longer than 30 s
    idx = np.searchsorted(src_t, t)
    idx = np.clip(idx, 1, len(src_t) - 1)
    gap = src_t[idx] - src_t[idx - 1]
    out[gap > 30] = np.nan
    return out


def floors_from_stairs(t, h):
    """Floors from stair (or lift) events, not from absolute height: weather drifts the barometer by 1-2 m an hour,
    which over a long indoor stretch would invent floors. Climbing shows as >= 1.2 m per minute (drift is ~40x
    slower); an event that changes height by >= 2.2 m counts as round(change / 3 m) floors. Between events the floor
    stays fixed. Floor 0 = where the recording started."""
    n = len(t)
    floor = np.full(n, np.nan)
    if np.isnan(h).all():
        return floor
    hs = lowpass(t, h, 10)
    W = 30
    rate = np.full(n, 0.0)
    rate[W:-W] = (hs[2 * W:] - hs[:-2 * W]) / (2 * W)          # m/s over a minute
    rate = np.nan_to_num(rate)
    climbing = np.abs(rate) > 0.02
    events = []
    i = 0
    while i < n:
        if climbing[i]:
            j = i
            while j < n and (climbing[j] or (j + 20 < n and climbing[j:j + 20].any())):
                j += 1
            a_, b_ = max(0, i - W), min(n - 1, j + W)
            change = np.nanmean(hs[b_:min(n, b_ + 20)]) - np.nanmean(hs[max(0, a_ - 20):a_ + 1])
            if abs(change) >= 2.2:
                events.append((a_, b_, int(round(change / FLOOR_M))))
            i = j
        else:
            i += 1
    # the floor changes halfway through each stair event and stays put in between
    level, start = 0, 0
    for a_, b_, df in events:
        mid = (a_ + b_) // 2
        floor[start:mid] = level
        level += df
        floor[mid:b_] = level
        start = b_
    floor[start:] = level
    floor[np.isnan(h)] = np.nan
    return floor


# ------------------------------------------------------------------ main pipeline

def build(d: Path):
    loc_paths = [p for p in (d / "phonelocation.csv", d / "location.csv") if p.exists()]
    fixes = [load(p, [0, 1, 2, 3, 4, 5, 6, 7]) for p in loc_paths]
    fixes = [f for f in fixes if f is not None]
    allfix = np.vstack(fixes) if fixes else None

    t0 = min(f[0, 0] for f in fixes) if fixes else None
    p_steps, steps_name = pick(d, "phonesteps", "steps")
    p_head, head_name = pick(d, "phoneheading", "heading")
    p_pres, _ = pick(d, "phonepressure", "pressure")
    p_abs, _ = pick(d, "phonealtitude", "altitude")
    steps = load(p_steps, [0, 1, 2, 3, 4]) if p_steps else None
    head = load(p_head, [0, 1, 2, 3, 4, 5]) if p_head else None
    pres = load(p_pres, [0, 2]) if p_pres else None
    absalt = load(p_abs, [0, 1, 2]) if p_abs else None
    starts = [a[0, 0] for a in (allfix, steps, head, pres) if a is not None]
    ends = [a[-1, 0] for a in (allfix, steps, head, pres) if a is not None]
    if not starts:
        raise SystemExit("no position data in this export (turn on Track position)")
    t = np.arange(math.floor(min(starts)), math.ceil(max(ends)) + 1, 1.0)
    n = len(t)

    # ---------- height
    rel = interp(t, pres[:, 0], pres[:, 1]) if pres is not None else np.full(n, np.nan)
    anchors_t, anchors_v, anchors_w = [], [], []
    if allfix is not None:
        g = allfix[(allfix[:, 5] > 0) & (allfix[:, 5] < 15)]
        anchors_t += list(g[:, 0]); anchors_v += list(g[:, 3]); anchors_w += list(1 / g[:, 5] ** 2)
    if absalt is not None:
        g = absalt[(absalt[:, 2] > 0) & (absalt[:, 2] < 15)]
        anchors_t += list(g[:, 0]); anchors_v += list(g[:, 1]); anchors_w += list(1 / g[:, 2] ** 2)
    alt = np.full(n, np.nan)
    if not np.isnan(rel).all():
        offset = np.full(n, np.nan)
        if anchors_t:
            at = np.array(anchors_t)
            idx = np.clip(np.searchsorted(t, at), 0, n - 1)
            diff = np.array(anchors_v) - rel[idx]
            raw_off = np.full(n, np.nan)
            wsum = np.zeros(n); vsum = np.zeros(n)
            ok = ~np.isnan(diff)
            np.add.at(wsum, idx[ok], np.array(anchors_w)[ok]); np.add.at(vsum, idx[ok], (diff * np.array(anchors_w))[ok])
            raw_off[wsum > 0] = vsum[wsum > 0] / wsum[wsum > 0]
            offset = lowpass(t, raw_off, 1800)                     # weather drift: 30 min
            if np.isnan(offset).all():
                offset[:] = np.nanmedian(diff)
            # hold the last known offset through long gaps
            last = np.nanmedian(diff)
            for i in range(n):
                if np.isnan(offset[i]):
                    offset[i] = last
                else:
                    last = offset[i]
        else:
            offset[:] = 0.0                                          # relative height only
        alt = rel + offset
    elif anchors_t:
        alt = interp(t, np.array(anchors_t), np.array(anchors_v))
    alt_s = lowpass(t, alt, 5)
    floor = floors_from_stairs(t, rel if not np.isnan(rel).all() else alt)

    # ---------- step distance per second (cumulative distance -> increments)
    dist = np.zeros(n)
    if steps is not None:
        cum = steps[:, 2] if not np.isnan(steps[:, 2]).all() else steps[:, 1] * 0.7
        cum_t = interp(t, steps[:, 0], cum)
        inc = np.diff(np.nan_to_num(cum_t, nan=0.0), prepend=0.0)
        inc[(inc < 0) | (inc > 4)] = 0.0                             # resets / glitches
        dist = inc

    # ---------- heading per second (circular mean of the 10 Hz stream)
    hdg = np.full(n, np.nan)
    if head is not None:
        h = head[head[:, 1] >= 0]
        if len(h):
            sec = np.floor(h[:, 0]).astype(np.int64)
            s0 = int(t[0])
            idx = sec - s0
            ok = (idx >= 0) & (idx < n)
            sx = np.zeros(n); sy = np.zeros(n); cnt = np.zeros(n)
            np.add.at(sx, idx[ok], np.sin(np.radians(h[ok, 1])))
            np.add.at(sy, idx[ok], np.cos(np.radians(h[ok, 1])))
            np.add.at(cnt, idx[ok], 1)
            m = cnt > 0
            hdg[m] = np.degrees(np.arctan2(sx[m], sy[m])) % 360

    # ---------- GPS per second: the better fix of the two devices
    lat0 = lon0 = None
    gx = np.full(n, np.nan); gy = np.full(n, np.nan); gacc = np.full(n, np.nan); gcourse = np.full(n, np.nan)
    if allfix is not None:
        good = allfix[(allfix[:, 4] > 0) & (allfix[:, 4] <= 50)]
        if len(good):
            lat0, lon0 = np.median(good[:, 1]), np.median(good[:, 2])
            for row in good[np.argsort(-good[:, 4])]:               # worst first, so the best one wins per second
                i = int(round(row[0] - t[0]))
                if 0 <= i < n:
                    gx[i] = math.radians(row[2] - lon0) * R_EARTH * math.cos(math.radians(lat0))
                    gy[i] = math.radians(row[1] - lat0) * R_EARTH
                    gacc[i] = row[4]
                    gcourse[i] = row[7] if row[7] >= 0 and row[6] > 0.6 else np.nan

    # ---------- heading offset (device -> walking direction), learned outdoors, per pocket period
    # A phone in a pocket keeps a fixed offset between where it points and where you walk, until it is taken out and
    # put back. Re-pocketings show as a jump of the phone's orientation (its z axis turning > 45 deg within 10 s);
    # each period between them gets its own offset from its own GPS walks. (Not for the watch: a wrist turns all the
    # time, so it keeps one offset for the day.)
    both = ~np.isnan(hdg) & ~np.isnan(gcourse) & (dist > 0.4) & (gacc < 15)
    bounds = [0]
    if head is not None and head_name == "phoneheading" and head.shape[1] >= 6:
        q = head[:, 2:6]
        zx = 2 * (q[:, 1] * q[:, 3] + q[:, 0] * q[:, 2]); zy = 2 * (q[:, 2] * q[:, 3] - q[:, 0] * q[:, 1])
        zz = 1 - 2 * (q[:, 1] ** 2 + q[:, 2] ** 2)
        sec = np.floor(head[:, 0] - t[0]).astype(int)
        ok = (sec >= 0) & (sec < n)
        Z = np.zeros((n, 3)); C = np.zeros(n)
        np.add.at(Z, sec[ok], np.column_stack([zx, zy, zz])[ok]); np.add.at(C, sec[ok], 1)
        have = C > 0
        Z[have] /= np.linalg.norm(Z[have], axis=1, keepdims=True)
        last = -999
        for i in range(10, n):
            if have[i] and have[i - 10]:
                ang = math.degrees(math.acos(max(-1.0, min(1.0, float(Z[i] @ Z[i - 10])))))
                if ang > 45 and i - last > 30:
                    bounds.append(i); last = i
    bounds.append(n)
    periods = []
    for a_, b_ in zip(bounds[:-1], bounds[1:]):
        m = both[a_:b_]
        if m.sum() >= 30:
            delta = (gcourse[a_:b_][m] - hdg[a_:b_][m]) % 360
            periods.append([a_, b_, circ_mean(delta), True])
        else:
            periods.append([a_, b_, None, False])
    learned = [p for p in periods if p[3]]
    borrowed = []
    for p in periods:
        if not p[3] and learned:
            near = min(learned, key=lambda L: min(abs(L[0] - p[1]), abs(L[1] - p[0])))
            p[2] = near[2]
            borrowed.append(p)
    offset_s = np.zeros(n)
    for a_, b_, off, _ in periods:
        offset_s[a_:b_] = off if off is not None else 0.0
    offset_deg = circ_mean(np.array([p[2] for p in learned])) if learned else 0.0
    walk_dir = (hdg + offset_s) % 360

    # ---------- Kalman filter (state x, y) + RTS smoother
    x = np.zeros((n, 2)); P = np.zeros((n, 2, 2))
    xp = np.zeros((n, 2)); Pp = np.zeros((n, 2, 2))
    first = np.flatnonzero(~np.isnan(gx))
    state = np.array([gx[first[0]], gy[first[0]]]) if len(first) else np.zeros(2)
    cov = np.eye(2) * (gacc[first[0]] ** 2 if len(first) else 1e6)
    for i in range(n):
        step = dist[i]
        if step > 0 and not np.isnan(walk_dir[i]):
            a = math.radians(walk_dir[i])
            state = state + np.array([math.sin(a), math.cos(a)]) * step
            q = (0.08 * step) ** 2 + (step * math.radians(12)) ** 2   # 8 % length, 12 deg heading error per step
        else:
            q = 0.05 ** 2 + (step ** 2 if step > 0 else 0)            # standing: barely moves; steps without heading: unknown
        cov = cov + np.eye(2) * q
        xp[i] = state; Pp[i] = cov
        if not np.isnan(gx[i]):
            Rm = np.eye(2) * max(gacc[i], 2.0) ** 2
            # reject fixes far outside the prediction (multipath indoors)
            innov = np.array([gx[i], gy[i]]) - state
            S = cov + Rm
            if innov @ np.linalg.solve(S, innov) < 25:
                K = cov @ np.linalg.inv(S)
                state = state + K @ innov
                cov = (np.eye(2) - K) @ cov
        x[i] = state; P[i] = cov
    xs = x.copy(); Ps = P.copy()
    for i in range(n - 2, -1, -1):
        C = P[i] @ np.linalg.inv(Pp[i + 1])
        xs[i] = x[i] + C @ (xs[i + 1] - xp[i + 1])
        Ps[i] = P[i] + C @ (Ps[i + 1] - Pp[i + 1]) @ C.T
    hacc = np.sqrt(np.maximum(Ps[:, 0, 0], Ps[:, 1, 1]))

    if lat0 is not None:
        lat = lat0 + np.degrees(xs[:, 1] / R_EARTH)
        lon = lon0 + np.degrees(xs[:, 0] / (R_EARTH * math.cos(math.radians(lat0))))
    else:
        lat = lon = None
    # seconds without any sensor within +-30 s (dead battery, app restarted, watch off the wrist): a gap, not a walk
    have = np.zeros(n, bool)
    for arr in (allfix, steps, head, pres):
        if arr is None:
            continue
        idx = np.clip(np.searchsorted(arr[:, 0], t), 1, len(arr) - 1)
        near = np.minimum(np.abs(arr[idx, 0] - t), np.abs(arr[idx - 1, 0] - t))
        have |= near <= 30
    src = np.where(~have, "gap", np.where(~np.isnan(gx) & (gacc < 15), "gps", np.where(dist > 0, "steps", "still")))
    warnings = []
    for p in borrowed:
        warnings.append(f"pocket period {p[0]//60:.0f}–{p[1]//60:.0f} min after start had no GPS walk: its direction "
                        f"is borrowed from the nearest period and may be off")
    if both.sum() < 30 and head is not None:
        warnings.append("no GPS walk to learn the pocket/wrist heading offset: the path's shape is right but it may be "
                        "rotated; the map orientation is not known")
    if lat0 is None:
        warnings.append("no GPS fix at all: positions are relative (metres from the start), not on a map")
    if pres is None:
        warnings.append("no barometer: height and floors come from GPS only and are coarse")
    return dict(t=t, x=xs[:, 0], y=xs[:, 1], lat=lat, lon=lon, alt=alt_s, floor=floor, hacc=hacc,
                src=src, dist=dist, offset=offset_deg, steps_src=steps_name, head_src=head_name, warnings=warnings,
                pocket_periods=[(int(p[0]), int(p[1]), None if p[2] is None else round(p[2], 1), p[3]) for p in periods])


def write(r, out: Path):
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "track.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["unix_time", "lat", "lon", "x_m", "y_m", "altitude_m", "floor", "h_acc_m", "source"])
        for i in range(len(r["t"])):
            w.writerow([f"{r['t'][i]:.0f}",
                        f"{r['lat'][i]:.7f}" if r["lat"] is not None else "", f"{r['lon'][i]:.7f}" if r["lon"] is not None else "",
                        f"{r['x'][i]:.2f}", f"{r['y'][i]:.2f}",
                        "" if np.isnan(r["alt"][i]) else f"{r['alt'][i]:.2f}",
                        "" if np.isnan(r["floor"][i]) else int(r["floor"][i]), f"{r['hacc'][i]:.1f}", r["src"][i]])
    if r["lat"] is not None:
        coords = [[round(float(r["lon"][i]), 7), round(float(r["lat"][i]), 7),
                   round(float(r["alt"][i]), 2) if not np.isnan(r["alt"][i]) else 0] for i in range(0, len(r["t"]), 5)]
        (out / "track.geojson").write_text(json.dumps({"type": "Feature", "properties": {"name": "Sage day"},
                                                       "geometry": {"type": "LineString", "coordinates": coords}}))


def write_html(r, out: Path, name: str):
    """track.html: tools/track_viewer.html with the day's points embedded (every 2 s), works offline"""
    step = 2
    pts = []
    for i in range(0, len(r["t"]), step):
        alt = None if np.isnan(r["alt"][i]) else round(float(r["alt"][i]), 2)
        fl = None if np.isnan(r["floor"][i]) else int(r["floor"][i])
        kind = {"gps": 0, "gap": 2}.get(r["src"][i], 1)
        pts.append([int(r["t"][i]), round(float(r["x"][i]), 2), round(float(r["y"][i]), 2), alt, fl,
                    round(float(r["hacc"][i]), 1), kind])
    data = {"name": name, "step": step, "tz": "Europe/Zurich", "points": pts, "warnings": r["warnings"]}
    tpl = (Path(__file__).parent / "track_viewer.html").read_text(encoding="utf-8")
    html = tpl.replace("const TRACK = /*DATA*/null;", "const TRACK = " + json.dumps(data, separators=(",", ":")) + ";")
    (out / "track.html").write_text(html, encoding="utf-8")


def summary(r):
    dist = r["dist"].sum()
    fl = r["floor"]
    changes = int(np.nansum(np.abs(np.diff(fl[~np.isnan(fl)])))) if not np.isnan(fl).all() else 0
    out = {"hours": (r["t"][-1] - r["t"][0]) / 3600, "walked_m": dist, "floor_changes": changes,
           "gps_share": float(np.mean(r["src"] == "gps")), "heading_offset_deg": r["offset"],
           "median_h_acc_m": float(np.median(r["hacc"][r["src"] != "gap"])) if (r["src"] != "gap").any() else None,
           "steps_from": r["steps_src"], "heading_from": r["head_src"],
           "gap_minutes": float((r["src"] == "gap").sum() / 60), "warnings": r["warnings"],
           "pocket_periods": [{"from_min": a // 60, "to_min": b // 60, "offset_deg": o, "learned": l}
                              for a, b, o, l in r["pocket_periods"]]}
    if not np.isnan(fl).all():
        out["minutes_per_floor"] = {int(k): float((fl == k).sum() / 60) for k in np.unique(fl[~np.isnan(fl)])}
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("export")
    ap.add_argument("--out", default=None)
    ap.add_argument("--html", action="store_true", help="also write track.html, an interactive 3D viewer")
    a = ap.parse_args()
    d = Path(a.export)
    res = build(d)
    out = Path(a.out) if a.out else d / "track"
    write(res, out)
    if a.html:
        write_html(res, out, d.name)
    print(json.dumps(summary(res), indent=2))
