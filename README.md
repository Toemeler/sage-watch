# Sage

A biphasic-sleep watch face for Apple Watch SE 3 (44 mm) and its iPhone companion.

- **Watch:** the Sage face full-screen, drawn 1:1 from the design prototype. Ten modes follow the day and the sleep plan (nap 17:00–18:30, night 00:30–06:30 with smart wake).
- **iPhone:** Today (24-hour ring), Sleep (night and nap stages), Plan, Faces.

## Build

No Mac needed: every push to `main` runs GitHub Actions on macOS. It runs the unit tests, builds an unsigned `Sage.ipa` with the watch app embedded, and attaches it to a release. The Xcode project is generated from `project.yml` by XcodeGen.

## Install

- **SideStore:** install `Sage.ipa`. The watch app then appears under Watch app → Available Apps. Required for the watch face and for Health data.
- **LiveContainer:** the iPhone app runs, but iOS cannot deliver the watch app from inside LiveContainer.

Apple does not allow third-party watch faces, so the face is a watch app. Set *Settings → General → Return to App* on the watch so it comes back on wrist raise.
