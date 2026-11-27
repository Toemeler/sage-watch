"""Synthetic day for testing track3d.py: a known true path (outdoor walk, building with stairs to floor 2,
indoor rounds, back out), turned into noisy sensor files in the export format. Prints the true facts so the
reconstruction can be scored."""
import json
import math
import sys
from pathlib import Path

import numpy as np

rng = np.random.default_rng(7)
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
T0 = 1_796_000_000.0
lat0, lon0, R = 47.37, 8.54, 6_371_000.0
segs = []  # (duration s, speed m/s, heading deg, climb m/s, indoors)
segs += [(120, 0, 0, 0, False)]                       # standing outside
segs += [(200, 1.3, 70, 0, False)]                    # walk to the building
segs += [(60, 1.2, 160, 0, True)]                     # into the building
segs += [(40, 0.5, 250, 0.15, True)]                  # stairs up one floor (6 m over 40 s -> 2 floors)
segs += [(300, 1.0, 340, 0, True), (60, 0, 0, 0, True), (300, 1.0, 160, 0, True)]   # rounds on floor 2
segs += [(40, 0.5, 70, -0.15, True)]                  # stairs down
segs += [(60, 1.2, 340, 0, True), (200, 1.3, 250, 0, False), (120, 0, 0, 0, False)]
t, x, y, z, indoor, spd = [T0], [0.0], [0.0], [420.0], [False], [0.0]
for dur, v, h, c, ind in segs:
    for _ in range(dur):
        a = math.radians(h)
        x.append(x[-1] + v * math.sin(a)); y.append(y[-1] + v * math.cos(a)); z.append(z[-1] + c)
        t.append(t[-1] + 1); indoor.append(ind); spd.append(v)
t, x, y, z, indoor, spd = map(np.array, (t, x, y, z, indoor, spd))
lat = lat0 + np.degrees(y / R); lon = lon0 + np.degrees(x / (R * math.cos(math.radians(lat0))))
# GPS (phone and watch) outdoors only, 1 Hz, 4 m noise; course from motion
course = np.degrees(np.arctan2(np.gradient(x), np.gradient(y))) % 360
with open(out / "phonelocation.csv", "w") as f:
    f.write("unix_time,lat,lon,alt_m,h_acc_m,v_acc_m,speed_mps,course_deg,floor\n")
    for i in range(len(t)):
        if indoor[i]:
            continue
        nx, ny = rng.normal(0, 4, 2)
        f.write(f"{t[i]:.3f},{lat[i] + math.degrees(ny / R):.7f},{lon[i] + math.degrees(nx / (R * math.cos(math.radians(lat0)))):.7f},"
                f"{z[i] + rng.normal(0, 5):.2f},5.0,6.0,{spd[i]:.2f},{course[i] if spd[i] > 0 else -1:.1f},\n")
# phone heading: device points 35 deg off the walking direction (pocket), compass noise 8 deg
with open(out / "phoneheading.csv", "w") as f:
    f.write("unix_time,heading_deg,qw,qx,qy,qz,ax,ay,az,rx,ry,rz\n")
    for i in range(len(t) - 1):
        for k in range(10):
            f.write(f"{t[i] + k / 10:.3f},{(course[i] - 35 + rng.normal(0, 8)) % 360:.1f},1,0,0,0,0,0,0,0,0,0\n")
# steps: cumulative distance with 5 % length error
with open(out / "phonesteps.csv", "w") as f:
    f.write("unix_time,steps,distance_m,floors_up,floors_down,cadence,pace\n")
    d = 0.0
    for i in range(0, len(t), 2):
        d += spd[i] * 2 * 1.05
        f.write(f"{t[i]:.3f},{int(d / 0.7)},{d:.3f},,,,\n")
# barometer: relative altitude with 0.1 m noise and 1.5 m/h weather drift
with open(out / "phonepressure.csv", "w") as f:
    f.write("unix_time,pressure_kpa,relative_altitude_m\n")
    for i in range(len(t)):
        f.write(f"{t[i]:.3f},95.0,{z[i] - 420 + rng.normal(0, 0.1) + (t[i] - T0) / 3600 * 1.5:.2f}\n")
np.save(out / "truth.npy", np.column_stack([t, x, y, z, indoor]))
print(json.dumps({"seconds": len(t), "walked_m": float(spd.sum()), "floor_changes_true": 4,
                  "indoor_s": int(indoor.sum())}))
