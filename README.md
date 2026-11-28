# Sage Data (data-lab branch)

A test build with only data, no watch face or other design: it gets as much data as it can off the Apple Watch, sends it to the iPhone, records it there and shows it.

- **Watch:** one screen, the data probe. Switch *Probe* on, or start it from the iPhone. A Mind & Body workout session keeps it recording in the background. The workout is discarded and never saved to Health. It records:
  - device motion at 50 Hz: acceleration, gravity, rotation, attitude, heading, magnetic field
  - the batched 800 Hz accelerometer and 200 Hz device motion, on watches that have them
  - barometer, absolute altitude, pedometer (steps, distance, floors, cadence, pace, pause/resume) and motion activity
  - GPS and the compass
  - every Health sample the watch holds, from 24 h back and then live, limited to what an Apple Watch SE 3 records: 29 quantity types, 10 category types, heartbeat series with beat-to-beat times, and workouts
  - live workout heart rate and energy
  - the watch's own status every 5 s: battery, temperature state, Low Power, Water Lock, wrist, app state, free space
- **Transfer:** CSV files in 2-minute chunks, compressed, through WatchConnectivity file transfers. They are resent until the iPhone has them. Live values go to the iPhone once a second while it is near.
- **iPhone:** one screen, the data lab:
  - every live value, with a chart of its history
  - the wrist's acceleration waveform
  - a log of every live snapshot, as a JSONL file you can share
  - every received run, with charts and the newest rows for each stream, and a zip to share
  - everything is also in Files › On My iPhone › Sage

## Build

Every push to `data-lab` (and `main`) runs GitHub Actions on macOS. It runs the unit tests, builds an unsigned `Sage.ipa` with the watch app embedded, and attaches it to a release. The Xcode project is generated from `project.yml` by XcodeGen.

## Install

The app uses the same bundle ID as Sage on `main`, so installing this IPA with SideStore replaces Sage. Install a `main` build to get the face back.
