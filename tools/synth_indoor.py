"""Synthetic long indoor day for floor detection under weather drift: 10 min outside with GPS, then 4 h inside a
building without GPS (floors 0 -> 2 -> 1 -> 0 by stairs at known times, walking around in between), then out again.
The barometer drifts 1.8 m/h (weather), so absolute height alone would invent floors. Writes the export files and
truth.npy (t, true floor)."""
import math
import sys
from pathlib import Path

import numpy as np

rng = np.random.default_rng(11)
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
T0, R, lat0, lon0 = 1_796_100_000.0, 6_371_000.0, 47.37, 8.54
FLOOR = 3.2
plan = [(600, 0, False)]                                     # (seconds, floor, indoors)
plan += [(3000, 0, True), (60, "up2", True), (5400, 2, True), (40, "down1", True), (3600, 1, True), (30, "lift1", True),
         (2400, 0, True), (600, 0, False)]
t, z, fl, ind, spd = [], [], [], [], []
cur_z, cur_f, now = 0.0, 0, T0
for dur, f, indoors in plan:
    for k in range(dur):
        if f == "up2":
            cur_z += 2 * FLOOR / dur; moving = 0.5
        elif f == "down1":
            cur_z -= FLOOR / dur; moving = 0.5
        elif f == "lift1":
            cur_z -= FLOOR / dur; moving = 0.0             # a lift: height changes, no steps
        else:
            cur_f = f; moving = 1.0 if (k // 120) % 3 == 0 else 0.0   # walk 2 min, stand 4 min
        t.append(now); z.append(cur_z); fl.append(round(cur_z / FLOOR)); ind.append(indoors); spd.append(moving)
        now += 1
t, z, fl, ind, spd = map(np.array, (t, z, fl, ind, spd))
drift = (t - T0) / 3600 * 1.8
with open(out / "phonepressure.csv", "w") as f:
    f.write("unix_time,pressure_kpa,relative_altitude_m\n")
    for i in range(len(t)):
        f.write(f"{t[i]:.3f},95.0,{z[i] + drift[i] + rng.normal(0, 0.08):.2f}\n")
with open(out / "phonelocation.csv", "w") as f:
    f.write("unix_time,lat,lon,alt_m,h_acc_m,v_acc_m,speed_mps,course_deg,floor\n")
    for i in range(len(t)):
        if not ind[i]:
            f.write(f"{t[i]:.3f},{lat0 + rng.normal(0, 3e-5):.7f},{lon0 + rng.normal(0, 3e-5):.7f},{430 + z[i] + rng.normal(0, 4):.2f},5,6,0,-1,\n")
with open(out / "phonesteps.csv", "w") as f:
    f.write("unix_time,steps,distance_m,floors_up,floors_down,cadence,pace\n")
    d = 0.0
    for i in range(0, len(t), 2):
        d += spd[i] * 2
        f.write(f"{t[i]:.3f},{int(d / 0.7)},{d:.3f},,,,\n")
np.save(out / "truth.npy", np.column_stack([t, fl]))
print(f"{(t[-1]-t[0])/3600:.1f} h, drift {drift[-1]:.1f} m by the end, true floor changes 4")
