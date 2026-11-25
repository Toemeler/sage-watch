# tools

`sleep_analysis.py` reads an export zip from the iPhone's Data tab and estimates, in 30-second epochs:
on/off wrist, movement and position changes, breathing rate (from raw motion while still), sleep vs. wake,
a heuristic stage (deep-like / light / REM-like) and the sleep cycles.

```
python3 tools/sleep_analysis.py Sage_20261124-2130_20261125-0900.zip --out analysis
```

Writes `summary.txt`, `summary.json`, `epochs.csv` and `night.png`. Needs Python 3.10+, pandas, numpy, matplotlib.

Sleep/wake from wrist motion is dependable. The stage labels are estimates: deep-like = lowest, steadiest heart rate
and breathing; REM-like = still body with irregular heart rate and breathing (not in the first 45 minutes).
Cycles end at each REM-like stretch of at least 4 minutes.
