## Install

**SideStore (needed for the watch app):** add `Sage.ipa` in SideStore, then install the watch app from the Watch app on iPhone (My Watch → Available Apps → Sage). Uses 3 of the 10 weekly App IDs of a free Apple ID (iPhone app, watch app, complications). Refresh in SideStore every 7 days.

**LiveContainer:** the iPhone app runs; the watch app, complications and Health data need the SideStore install.

## New in 0.3.2

- The system time in the top-right corner is hidden on the face, so there is only one clock.

## New in 0.3.1

- **No more lost heart-rate samples while the screen is off.** watchOS delivers them in batches then; the recorder now writes every sample of a batch, not just the newest.

## New in 0.3

- **Recorder.** Long-press the face → *Record*. Sage runs a Mind & Body session so it stays in front around the clock (wrist raise always brings it back) and records:
  heart rate about every 5 s, a per-second motion summary, raw motion up to 100 Hz (optionally with the gyroscope), air pressure, and battery/charging once a minute.
  Files go to the iPhone every 30–60 minutes. Nothing is saved to Apple Health unless *Save to Health* is on.
- **Data tab on iPhone.** Export the last nap, the last night, the last 24 hours or any range as one zip of CSV files. Recordings and exports are also in the Files app (On My iPhone › Sage).
- **Start from the iPhone.** Data → *Start recording on the watch*, handy after charging.
- **Smart alarm** runs inside the recorder while it records (vibration only when the watch is in Silent Mode), and a window you already woke from is no longer armed again.
- The face shows the live heart rate while recording; a small sage dot at the top means the recorder is on.
