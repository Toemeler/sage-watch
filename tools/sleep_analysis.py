#!/usr/bin/env python3
"""Sleep analysis for a Sage recorder export.

Reads the zip from the iPhone's Data tab (or the unzipped folder) and estimates, per 30-second epoch:
- on/off wrist (charging, missing heart rate),
- movement (wrist motion, position changes),
- breathing rate from the raw accelerometer (wrist micro-motion while still, when raw.csv is present),
- sleep vs. wake, and within sleep a heuristic stage (deep-like / light / REM-like) from heart rate level,
  heart rate irregularity and breathing irregularity,
- sleep cycles, ending at each REM-like stretch.

These are estimates from wrist data, not polysomnography. Sleep/wake from motion is reliable; the stage labels are
a rough guide (deep: lowest, steadiest heart rate and breathing; REM: still body with irregular heart rate and breathing).

usage: sleep_analysis.py EXPORT.zip [--from "2026-11-25 00:00"] [--to "2026-11-25 09:00"] [--tz Europe/Zurich] [--out DIR]
writes: summary.txt, summary.json, epochs.csv, night.png
"""
import argparse
import json
import sys
import zipfile
from pathlib import Path

import numpy as np
import pandas as pd

EPOCH = 30  # seconds
STAGES = {0: "wake", 1: "REM-like", 2: "light", 3: "deep-like", -1: "off wrist"}


# ---------------------------------------------------------------- loading

def load(path: Path) -> tuple[dict, list]:
    frames, metas = {}, []

    def take(name: str, fh):
        base = Path(name).name
        if base.endswith(".csv"):
            frames[base[:-4]] = pd.read_csv(fh, on_bad_lines="skip")
        elif base == "segments.json":
            metas.extend(json.load(fh))

    if path.is_dir():
        for f in path.rglob("*"):
            if f.is_file():
                with open(f, "rb") as fh:
                    take(f.name, fh)
    else:
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                if not n.endswith("/"):
                    with z.open(n) as fh:
                        take(n, fh)
    if "raw_gyro" in frames and "raw" not in frames:
        frames["raw"] = frames["raw_gyro"]
    return frames, metas


# ---------------------------------------------------------------- epochs

def build_epochs(frames: dict, lo: float, hi: float) -> pd.DataFrame:
    m = frames.get("motion1s")
    if m is None or m.empty:
        sys.exit("motion1s.csv is missing: nothing to analyse")
    m = m[(m.unix_second >= lo) & (m.unix_second <= hi)].sort_values("unix_second").copy()
    t0 = np.floor(m.unix_second.min() / EPOCH) * EPOCH
    t1 = np.ceil((m.unix_second.max() + 1) / EPOCH) * EPOCH
    df = pd.DataFrame(index=pd.Index(np.arange(t0, t1, EPOCH), name="t"))

    # movement: within-second spread of |a| and wrist rotation between seconds (position changes)
    v = m[["mean_x", "mean_y", "mean_z"]].to_numpy(dtype=float)
    norm = np.linalg.norm(v, axis=1, keepdims=True)
    u = v / np.where(norm == 0, 1, norm)
    cosang = np.clip(np.sum(u[1:] * u[:-1], axis=1), -1, 1)
    m["turn_deg"] = np.concatenate([[0.0], np.degrees(np.arccos(cosang))])
    m["epoch"] = (m.unix_second // EPOCH) * EPOCH
    g = m.groupby("epoch")
    df["sd_g"] = g.sd_g.mean()
    df["sd_g_max"] = g.sd_g.max()
    df["turn_deg"] = g.turn_deg.sum()
    df["seconds"] = g.size()

    hr = frames.get("hr")
    if hr is not None and not hr.empty:
        hr = hr[(hr.unix_start >= lo - 600) & (hr.unix_start <= hi + 600)].sort_values("unix_start").copy()
        hr["epoch"] = (hr.unix_start // EPOCH) * EPOCH
        df["hr"] = hr.groupby("epoch").bpm.mean()
        # irregularity: spread of the ~5 s heart rate in a 5-minute window, after removing the slow trend
        s = hr.set_index(pd.to_datetime(hr.unix_start, unit="s")).bpm
        trend = s.rolling("10min", center=True, min_periods=5).median()
        resid = (s - trend).abs()
        irr = resid.rolling("5min", center=True, min_periods=8).mean()
        hr["irr"] = irr.to_numpy()
        df["hr_irr"] = hr.groupby("epoch").irr.mean()
    else:
        df["hr"] = np.nan
        df["hr_irr"] = np.nan

    st = frames.get("status")
    df["charging"] = False
    if st is not None and not st.empty:
        st = st.sort_values("unix_time")
        for t, state in zip(st.unix_time, st.battery_state):
            if state in ("charging", "full"):
                df.loc[(df.index >= t - 60) & (df.index < t + 60), "charging"] = True

    raw = frames.get("raw")
    if raw is not None and not raw.empty:
        df = df.join(breathing(raw, lo, hi), how="left")
    else:
        df["breaths"] = np.nan
        df["breath_irr"] = np.nan
    return df


def breathing(raw: pd.DataFrame, lo: float, hi: float, window: int = 60) -> pd.DataFrame:
    """Breathing rate per epoch from wrist micro-motion: the dominant 0.12–0.6 Hz rhythm of the axis that carries
    most of it, in 60-second windows. Only meaningful while the arm is still."""
    raw = raw[(raw.unix_time >= lo) & (raw.unix_time <= hi)].sort_values("unix_time")
    t = raw.unix_time.to_numpy(dtype=float)
    if len(t) < 1000:
        return pd.DataFrame(columns=["breaths", "breath_irr"])
    fs = 1.0 / np.median(np.diff(t))
    xyz = raw[["x", "y", "z"]].to_numpy(dtype=float)
    out = {}
    start = np.floor(t[0] / EPOCH) * EPOCH
    n = int(window * fs)
    for e in np.arange(start, t[-1] - window, EPOCH):
        i0 = np.searchsorted(t, e)
        seg = xyz[i0:i0 + n]
        if len(seg) < 0.9 * n:
            continue
        if seg.std(axis=0).max() > 0.02:          # arm moving: no breathing estimate
            continue
        best = None
        for k in range(3):
            y = seg[:, k] - np.polyval(np.polyfit(np.arange(len(seg)), seg[:, k], 1), np.arange(len(seg)))
            spec = np.abs(np.fft.rfft(y * np.hanning(len(y)))) ** 2
            f = np.fft.rfftfreq(len(y), 1 / fs)
            band = (f >= 0.12) & (f <= 0.6)
            if not band.any():
                continue
            sb, fb = spec[band], f[band]
            j = int(np.argmax(sb))
            power = sb[j]
            prominence = power / (np.median(sb) + 1e-12)
            peak = fb[j]
            if 0 < j < len(sb) - 1:                 # parabolic interpolation between FFT bins
                a, b, c = np.log(sb[j - 1] + 1e-18), np.log(sb[j] + 1e-18), np.log(sb[j + 1] + 1e-18)
                denom = a - 2 * b + c
                if denom != 0:
                    peak = fb[j] + 0.5 * (a - c) / denom * (fb[1] - fb[0])
            if best is None or power > best[0]:
                best = (power, peak * 60, prominence)
        if best and best[2] > 6:
            out[e + EPOCH] = best[1]               # stamp the window's centre epoch
    s = pd.Series(out, name="breaths", dtype=float)
    s.index.name = "t"
    irr = s.rolling(10, center=True, min_periods=4).std()
    return pd.DataFrame({"breaths": s, "breath_irr": irr})


# ---------------------------------------------------------------- scoring

def score(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    no_hr = df.hr.isna().rolling(20, center=True, min_periods=1).mean() > 0.9
    df["off"] = df.charging | (no_hr & (df.sd_g < df.sd_g.quantile(0.05) * 1.2))

    on = df[~df.off]
    noise = on.sd_g.quantile(0.10) if len(on) else df.sd_g.quantile(0.10)
    df["moving"] = (df.sd_g_max > max(noise * 4, 0.004)) | (df.turn_deg > 15)

    # sleep: little movement in the surrounding 10 minutes
    frac = df.moving.astype(float).rolling(21, center=True, min_periods=5).mean()
    asleep = (frac < 0.12) & ~df.off
    asleep = rescore(asleep, min_sleep=20, max_wake_gap=2)
    df["asleep"] = asleep

    # stages inside sleep, relative to this recording's own sleep
    stage = pd.Series(0, index=df.index)
    stage[df.off] = -1
    sl = df[df.asleep]
    if len(sl) > 20:
        hr_s = df.hr.rolling(6, center=True, min_periods=2).mean()
        z_hr = (hr_s - hr_s[df.asleep].mean()) / (hr_s[df.asleep].std() + 1e-9)
        irr = df.hr_irr.fillna(df.hr_irr[df.asleep].median())
        z_irr = (irr - irr[df.asleep].mean()) / (irr[df.asleep].std() + 1e-9)
        b_irr = df.breath_irr
        z_b = ((b_irr - b_irr[df.asleep].mean()) / (b_irr[df.asleep].std() + 1e-9)).fillna(0) if b_irr.notna().sum() > 20 else pd.Series(0.0, index=df.index)
        still = ~df.moving.rolling(5, center=True, min_periods=1).max().astype(bool)
        onset = episode_start(df.asleep)
        minutes_in = (df.index.to_series() - onset) / 60

        light = df.asleep
        deep = df.asleep & still & (z_hr < -0.4) & (z_irr < -0.2) & (z_b < 0.5)
        rem = df.asleep & still & ((z_irr + z_b) / 2 > 0.45) & (z_hr > -0.3) & (minutes_in > 45)
        stage[light] = 2
        stage[deep] = 3
        stage[rem & ~deep] = 1
        stage[df.asleep & df.moving] = 0
        stage = mode_filter(stage, 5)
    stage[~df.asleep & ~df.off] = 0
    df["stage"] = stage
    return df


def rescore(asleep: pd.Series, min_sleep: int, max_wake_gap: int) -> pd.Series:
    """Fill wake gaps of <= max_wake_gap minutes inside sleep, then drop sleep stretches shorter than min_sleep minutes."""
    a = asleep.to_numpy().copy()
    runs = runs_of(a)
    for v, i, n in runs:
        if not v and n * EPOCH / 60 <= max_wake_gap and i > 0 and i + n < len(a):
            a[i:i + n] = True
    for v, i, n in runs_of(a):
        if v and n * EPOCH / 60 < min_sleep:
            a[i:i + n] = False
    return pd.Series(a, index=asleep.index)


def runs_of(a: np.ndarray) -> list:
    out, i = [], 0
    while i < len(a):
        j = i
        while j < len(a) and a[j] == a[i]:
            j += 1
        out.append((a[i], i, j - i))
        i = j
    return out


def episode_start(asleep: pd.Series) -> pd.Series:
    """for every epoch, the start time of the sleep episode it belongs to (NaN when awake)"""
    starts = pd.Series(np.nan, index=asleep.index)
    current = np.nan
    prev = False
    for t, v in asleep.items():
        if v and not prev:
            current = t
        starts[t] = current if v else np.nan
        prev = v
    return starts


def mode_filter(stage: pd.Series, width: int) -> pd.Series:
    vals = stage.to_numpy()
    out = vals.copy()
    h = width // 2
    for i in range(len(vals)):
        if vals[i] <= 0:
            continue
        w = vals[max(0, i - h):i + h + 1]
        w = w[w > 0]
        if len(w):
            out[i] = np.bincount(w).argmax()
    return pd.Series(out, index=stage.index)


# ---------------------------------------------------------------- cycles and summary

def episodes(df: pd.DataFrame) -> list:
    eps = []
    for v, i, n in runs_of(df.asleep.to_numpy()):
        if v:
            eps.append((df.index[i], df.index[i + n - 1] + EPOCH))
    return eps


def cycles(df: pd.DataFrame, start: float, end: float) -> list:
    """Cycle boundaries at the end of each REM-like stretch (>= 4 min, gaps < 5 min merged, cycles >= 45 min)."""
    part = df[(df.index >= start) & (df.index < end)]
    rem = (part.stage == 1).to_numpy()
    merged = rem.copy()
    for v, i, n in runs_of(rem):
        if not v and n * EPOCH / 60 < 5 and i > 0 and i + n < len(rem):
            merged[i:i + n] = True
    bounds = [start]
    for v, i, n in runs_of(merged):
        if v and n * EPOCH / 60 >= 4:
            b = part.index[i + n - 1] + EPOCH
            if b - bounds[-1] >= 45 * 60:
                bounds.append(b)
    out = []
    for a, b in zip(bounds, bounds[1:]):
        out.append({"start": a, "end": b, "minutes": round((b - a) / 60), "complete": True})
    if end - bounds[-1] >= 10 * 60:
        out.append({"start": bounds[-1], "end": end, "minutes": round((end - bounds[-1]) / 60), "complete": False})
    return out


def summarize(df: pd.DataFrame, tz: str) -> dict:
    fmt = lambda t: pd.Timestamp(t, unit="s", tz="UTC").tz_convert(tz).strftime("%Y-%m-%d %H:%M")
    result = {"time_zone": tz, "epoch_seconds": EPOCH, "episodes": []}
    for a, b in episodes(df):
        part = df[(df.index >= a) & (df.index < b)]
        minutes = {STAGES[k]: round(int((part.stage == k).sum()) * EPOCH / 60) for k in (0, 1, 2, 3)}
        asleep_min = minutes["REM-like"] + minutes["light"] + minutes["deep-like"]
        cyc = cycles(df, a, b)
        complete = [c["minutes"] for c in cyc if c["complete"]]
        result["episodes"].append({
            "start": fmt(a), "end": fmt(b),
            "span_min": round((b - a) / 60), "asleep_min": asleep_min,
            "stages_min": minutes,
            "position_changes": int((part.turn_deg > 30).sum()),
            "hr_min": None if part.hr.isna().all() else round(float(part.hr.min()), 1),
            "hr_mean": None if part.hr.isna().all() else round(float(part.hr.mean()), 1),
            "breaths_per_min": None if part.breaths.isna().all() else round(float(part.breaths.median()), 1),
            "cycles": [{"start": fmt(c["start"]), "end": fmt(c["end"]), "minutes": c["minutes"], "complete": c["complete"]} for c in cyc],
            "average_cycle_min": round(sum(complete) / len(complete)) if complete else None,
        })
    return result


def text(summary: dict) -> str:
    lines = [f"Sage sleep analysis ({summary['time_zone']}, {summary['epoch_seconds']} s epochs) — estimates from wrist data", ""]
    if not summary["episodes"]:
        lines.append("No sleep found in this range.")
    for e in summary["episodes"]:
        st = e["stages_min"]
        lines += [
            f"{e['start']} → {e['end']}   asleep {e['asleep_min']} min of {e['span_min']}",
            f"  stages (estimated): deep-like {st['deep-like']} · light {st['light']} · REM-like {st['REM-like']} · awake {st['wake']} min",
            f"  heart: low {e['hr_min']} · mean {e['hr_mean']} bpm   breathing: {e['breaths_per_min']} /min   position changes: {e['position_changes']}",
        ]
        for i, c in enumerate(e["cycles"], 1):
            lines.append(f"  cycle {i}: {c['start'][11:]} → {c['end'][11:]}  {c['minutes']} min{'' if c['complete'] else '  (cut off)'}")
        if e["average_cycle_min"]:
            lines.append(f"  average complete cycle: {e['average_cycle_min']} min")
        lines.append("")
    return "\n".join(lines)


def plot(df: pd.DataFrame, summary: dict, tz: str, path: Path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates

    x = pd.to_datetime(df.index, unit="s", utc=True).tz_convert(tz)
    rows = 4 if df.breaths.notna().any() else 3
    fig, ax = plt.subplots(rows, 1, figsize=(11, 2.1 * rows + 0.6), sharex=True,
                           gridspec_kw={"height_ratios": [1.4] + [1] * (rows - 1)})
    level = df.stage.map({0: 4, 1: 3, 2: 2, 3: 1, -1: np.nan})
    colours = {4: "#D85A30", 3: "#85B7EB", 2: "#378ADD", 1: "#185FA5"}
    for lv, c in colours.items():
        sel = level == lv
        ax[0].bar(x[sel], 0.8, bottom=lv - 0.4, width=EPOCH / 86400, color=c, linewidth=0)
    ax[0].set_yticks([1, 2, 3, 4], ["deep-like", "light", "REM-like", "awake"])
    ax[0].set_ylim(0.4, 4.6)
    for e in summary["episodes"]:
        for c in e["cycles"]:
            t = pd.Timestamp(c["end"]).tz_localize(tz)
            if c["complete"]:
                ax[0].axvline(t, color="#888780", ls=":", lw=1)
    ax[0].set_title("Estimated stages and cycles (wrist data, not a sleep lab)", fontsize=10, loc="left")

    ax[1].plot(x, df.hr, color="#D85A30", lw=1)
    ax[1].set_ylabel("bpm")
    ax[2].fill_between(x, 0, df.sd_g, color="#888780", step="mid")
    ax[2].set_ylabel("movement (g)")
    if rows == 4:
        ax[3].plot(x, df.breaths, ".", ms=2, color="#1D9E75")
        ax[3].set_ylabel("breaths/min")
    ax[-1].xaxis.set_major_formatter(mdates.DateFormatter("%H:%M", tz=x.tz))
    for a in ax:
        a.spines[["top", "right"]].set_visible(False)
        a.grid(axis="y", color="#e1e0d9", lw=0.6)
    fig.tight_layout()
    fig.savefig(path, dpi=150)


# ---------------------------------------------------------------- main

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("export", type=Path)
    p.add_argument("--from", dest="start")
    p.add_argument("--to", dest="end")
    p.add_argument("--tz")
    p.add_argument("--out", type=Path, default=Path("analysis"))
    a = p.parse_args()

    frames, metas = load(a.export)
    tz = a.tz or next((m.get("time_zone") for m in metas if m.get("time_zone")), "Europe/Zurich")
    lo = pd.Timestamp(a.start, tz=tz).timestamp() if a.start else -np.inf
    hi = pd.Timestamp(a.end, tz=tz).timestamp() if a.end else np.inf

    df = score(build_epochs(frames, lo, hi))
    summary = summarize(df, tz)
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / "summary.json").write_text(json.dumps(summary, indent=2))
    (a.out / "summary.txt").write_text(text(summary))
    out = df.copy()
    out.insert(0, "local_time", pd.to_datetime(out.index, unit="s", utc=True).tz_convert(tz).strftime("%Y-%m-%d %H:%M:%S"))
    out["stage_name"] = out.stage.map(STAGES)
    out.to_csv(a.out / "epochs.csv")
    plot(df, summary, tz, a.out / "night.png")
    print(text(summary))


if __name__ == "__main__":
    main()
