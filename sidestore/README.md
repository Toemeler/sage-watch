# SideStore Watch (for Sage)

Unofficial SideStore build that can install Sage on both the iPhone and the Apple Watch with Apple Health access, using a free Apple ID. It is based on [Andris73's watch-companion branch](https://github.com/Andris73/SideStore/tree/fix/issue-229-watch-companion), plus the patches in `sidestore/patch.py`. That branch registers the watch, gets watchOS profiles, and pushes the watch app over the developer channel, the same path Xcode uses.

## What the patches add

- **HealthKit:** asks Apple for the HealthKit capability (`HK421J6T7P`) on the iPhone and watch App IDs. If Apple refuses it, the install continues without it instead of failing.
- **Watch extensions:** bundles inside `Watch/` get watchOS profiles. Sage's complication extension needs this.
- **Watch App ID:** the watch App ID is updated with `DTDK_Platform=watchos` first, the way Xcode does it.
- **Sign-in fix (HTTP 503 since 2026-11-20):** sends `Mac OS X` instead of `macOS` in the client-info header.
- **2FA fix:** retries 2FA on HTTP 409 (SideStore/SideSign `752d1ef`).
- **Refresh renews the watch app too:** the new watch profile is pushed to the watch's profile store. If the watch is out of reach, the iPhone refresh still finishes.
- **Trust only once:** the watch pairing is saved, so you tap Trust on the watch once. A background refresh never waits for a Trust prompt.

## Install

1. **Replace your SideStore.** Download `SideStore.ipa` from this release and install it with iloader on the PC, the same way you installed SideStore before. It keeps SideStore's app ID and name, so iloader recognises it and places the pairing file. Check Settings in SideStore: the version should end in `-watch.N`.
2. **Turn on Developer Mode on the watch.** On the watch: Settings → Privacy & Security → Developer Mode → On. The watch restarts and asks you to confirm.
3. **Sign in to SideStore Watch** with your Apple ID.
4. **Install Sage.** On the iPhone, download `Sage.ipa` from the latest Sage release. In SideStore Watch, go to My Apps → **+** and pick the file. Keep the watch on your wrist, unlocked, next to the phone.
5. **Tap Trust on the watch.** On the first install a pairing prompt appears on the watch. Scroll down and tap **Trust**. SideStore looks busy until you do. The watch app then copies over, which takes a minute or two.
6. **Allow Health access.** Open Sage on the watch and allow Health access when asked.

## Every week

SideStore refreshes Sage on its own, and this build also renews the watch app.

If the watch app ever stops opening: in SideStore, long-press Sage → **Reinstall → From Cache**, with the watch nearby. This re-signs both apps and pushes the watch app again.

## If something fails

Open SideStore → Settings → Techy Things → Console Log. Look for these lines:

- Watch install: `[InstallAppOperation][watch]`
- Watch refresh: `[RefreshAppOperation][watch]`
- App ID features: `Feature update`

A failed watch install doesn't undo the iPhone install.

Limits of a free Apple ID: Sage uses 3 App IDs (iPhone app, watch app, complication). The limit is 10 new App IDs per 7 days.
