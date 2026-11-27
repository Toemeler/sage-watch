# Sage design log

Running notes from the design loop: what was researched, what changed, what is next.
Every change lands in both the HTML prototype (`tools/face-preview/index.html`, published as "Sage Face Preview")
and the Swift app (`Watch/LampPanel.swift`, `Shared/FaceRenderer.swift`).

## Reference notes

- **Control Center slider (iOS):** no Apple documentation of the stretch. Common recreations use the scroll-view
  rubber band `(1 - 1 / (x * 0.55 / d + 1)) * d` and spring back on release; modules "grow toward the finger".
  [Motion iOS slider](https://motion.dev/tutorials/react-ios-slider)
- **Digital Crown (HIG):** turning it must visibly change the control; use the system's haptic detents; anything the
  crown does must also work by touch. [Digital Crown](https://developer.apple.com/design/human-interface-guidelines/digital-crown.md),
  [WWDC23 Design and build apps for watchOS 10](https://developer.apple.com/videos/play/wwdc2023/10026)
- **Home app on Apple Watch:** tap an accessory to toggle; open it and turn the crown or swipe up/down for brightness;
  swipe sideways for colours. [iMore](https://imore.com/how-use-home-app-apple-watch),
  [Apple Support](https://support.apple.com/guide/watch/apddad023a05)
- **App grid (Bubble UI):** a centre zone at full size and a fringe around it where bubbles shrink to a minimum while
  being translated inward; critics note that icons away from the centre are harder to hit until scrolled to the middle.
  [Deconstructing the Apple Watch Bubble UI](https://blakesanie.substack.com/p/deconstructing-the-iconic-apple-watch),
  [tempertemper](https://www.tempertemper.net/blog/apple-watchs-default-app-view-is-bad)

## Quality gate (every round, every change)

1. Review the diff line by line before committing: concurrency (actors, cancelled tasks), every state the code can
   be in (iPhone unreachable, app in background, lamp off, user mid-gesture), and who wins when the user and an
   automation act at once — **the user always wins; automation never undoes a manual change.**
2. Logic that decides anything (times, levels, averages) gets a unit test; CI must be green (tests + build) before
   an IPA is sent. A red build is fixed in the same round, never left.
3. The HTML prototype and Swift stay in step; the design log says what changed, why, and what is unverified.
4. Nothing is called done that was not run: say what was verified (CI, tests) and what needs the real watch.

## Proposed features

Proposals wait one round for Tom's answer; unanswered ones are built in the next round, each on its own commit.
Direction from Tom: focus on the watch app itself; only the watch's smart wake wakes him (no iPhone alarms, no widgets).

| # | Feature | Status |
|---|---------|--------|
| F1 | **Sunrise wake light:** the lamp fades up warm while the wake window is open; full light when the alarm rings (night and nap) | built (round 2, no answer) |
| F2 | **Evening wind-down:** in the hour before the night's bedtime a lamp that is on dims and warms; a manual change pauses it | built (round 2, no answer) |
| F3 | ~~Single lamps~~ | rejected: Tom has one lamp |
| F4 | **Crown zoom in the colour wheel:** turning the crown zooms out to see all 61 colours at once, like the app grid | built (round 2, no answer) |
| F5 | ~~Wake light from the iPhone alarm~~ | rejected: only the watch's smart wake wakes Tom |
| F6 | **Off when asleep:** when the watch finds you asleep (night or nap), a lamp that is on fades off in two steps | built (round 3, no answer) |
| F7 | ~~Lamp in the Smart Stack~~ | rejected: not needed, focus on the watch app itself |
| F8 | **Today ring from your real sleep:** the iPhone Today ring draws your usual nap and night (averages of the recorded ones) as the main arcs, with the plan's presets as a faint outline behind them | built (round 4, no answer) |
| F9 | **Nap from the face:** crown up opens the lamp; a long turn down (12 detents) starts a nap, with a note and Undo for 3 s | built (round 5, no answer) |
| F10 | **Bedside mode:** while the watch charges at night, the face shows only the time in deep red at minimum brightness (no runner, no music), like a bedside clock that does not light the room | built (round 5, no answer) |
| F11 | **Double tap toggles the lamp:** on watches with the double-tap gesture (pinch twice), double tap on the face switches the lamp on or off, with the click haptic; nothing during a sleep block | built (round 7, no answer) |
| F12 | **Night light from the bedside clock:** on the charger at night, turning the crown sets the lamp to a dim red night light (5 %), for getting up without waking fully; turning back down switches it off. Never bright | proposed (round 9) |
| F13 | **Bedtime tap:** at your usual bedtime, if the lamp is still bright and wind-down is off, one quiet tap on the wrist with "Bedtime" (no sound); nothing if the lamp is already dim or off | proposed (round 9) |

## Iterations

### 1 · 2026-11-26 — honeycomb reach and focus
- **Found:** the pan limit (46 pt) was smaller than the outer ring's distance (94 pt), so the twelve hues could never
  reach the full-size centre zone; the grid also always opened on the middle white.
- **Changed:** pan limit = 2 × pitch on each axis (rubber band beyond); the grid opens centred on the colour that is
  set; the fringe follows the Bubble UI model (centre zone inset 0.75 bubble, 1.1-bubble fringe, smoothstep down to
  38 % size, inward pull up to half a bubble).
- **Next ideas:** colour bubbles could carry a soft glow of their own colour on black; a hue ring that tracks the
  crown inside the honeycomb; check the capsule's proportions against the real Control Center module (iOS 26).

### 2 · 2026-11-26 — the whole display is the slider (user feedback)
- **Feedback:** the lamp screen should use the whole screen.
- **Changed:** the capsule became the display itself (3 pt inset, corners at 20 % of the short side, like the
  display's), drawn under the toolbar with only the close button on top. Tap, slide and hold work anywhere.
  The percentage shows large (40 pt) in the middle while it changes, dark on the fill and white on the track.
  The bulb icon sits at the bottom. With no room to grow, the press feedback is a slightly brighter track,
  and the rubber band is a gentle stretch of the whole slider (at most 7 % of the height) away from the fixed edge.

### 3 · 2026-11-26 — music indicator missing while listening (user report)
- **Report:** music was playing but the bars above the battery did not show.
- **Likely cause:** the iPhone answered with `AVAudioSession.isOtherAudioPlaying` only, from an app that never set an
  audio category; that read is unreliable for apps like Spotify.
- **Changed:** the iPhone sets the quietest category (ambient, mix with others; never activated, so nothing pauses)
  and reports playing when either `isOtherAudioPlaying` or `secondaryAudioShouldBeSilencedHint` (another app plays
  non-mixable audio) is true. The watch checks every 10 s instead of 20 s.
- **Diagnostics:** the iPhone Faces tab has a live "Music on the watch" card; the watch's long-press menu shows the
  last answer ("Playing", "Nothing playing", "iPhone not reachable", ...) with "Check again".

### 4 · 2026-11-26 — reliability, crown to open, no accidental picks (user feedback)
- **Feedback:** connecting takes long and fails often; dragging around the colours keeps selecting one; wants the
  crown to open the lamp; asks whether it could work without the iPhone.
- **Without the iPhone:** not directly. watchOS only allows UDP for apps with an active audio streaming session, and
  developers report even that path being revoked after ~35 s ([TN3135 thread](https://developer.apple.com/forums/thread/717615),
  [revoke cycle](https://developer.apple.com/forums/thread/841590?answerId=902282022)). URLSession (HTTP) does work
  on the watch, so a small always-on HTTP→UDP bridge at home would remove the iPhone from the path.
- **Changed:**
  - Colour grid: one gesture decides; a touch that travels more than 6 pt pans and never picks; a still tap picks the
    bubble under it by its drawn (fisheye) size, or goes back on empty space.
  - Face: a deliberate crown turn opens the lamp panel (with a click).
  - Connection: the watch keeps the last good state (15 min) and opens with it instantly; each message waits up to
    3 s for the iPhone, then retries twice (0.3 s, 0.9 s); only a failed status check marks "not home".
    The iPhone answers a change straight from the setPilot replies (no second getPilot round) and uses 0.5 s UDP
    timeouts with two retries per bulb.

### 5 · 2026-11-26 — more colours outward (user feedback)
- **Feedback:** more colours further out.
- **Changed:** the honeycomb grew from 2 to 4 rings and became a colour wheel: whites in the centre and first ring,
  then 12 pastels (40 % saturation), 18 richer hues (72 %) and 24 vivid ones (100 %), 61 bubbles in all. The pan
  reaches the outermost ring; the bloom staggers 40 ms per ring.

### 6 · 2026-11-26 — critical round 1
**Review (senior design/engineering pass):**
1. *Failure honesty (high).* A change that never reached the bulbs left the slider showing a state the room did not
   have: optimistic UI without reconciliation. Production apps roll back and say so.
2. *Reduce Motion (high, accessibility).* Bloom, rubber band, zoom and blur all ignored the system setting.
3. *Percentage legibility (medium).* The label flipped from white to dark at 55 % while the fill edge crossed it,
   so for a few percent it sat half on the fill in the wrong colour. Control Center splits the glyphs at the edge.
4. *VoiceOver (medium).* 48 of 61 bubbles were announced as "Colour".
5. *Noted, not fixed yet:* the crown does nothing in the colour wheel (HIG: the crown should always do something
   visible) → proposed as F4; a failed status check while the panel is open swaps it for the error view abruptly;
   pastel RGB on WiZ bulbs is dimmer than the swatch suggests (RGB LEDs only, no white channel mixed in).
6. *Research:* `WKHapticType.directionUp/Down` pair with tones, so they would beep on every toggle; `.click` stays
   for touches, `.failure` is right for a change that failed. [WKHapticType](https://developer.apple.com/documentation/watchkit/wkhaptictype.md)

**Changed:**
- A change that fails after all retries falls back to the last state the lamps confirmed, plays `.failure` and
  shows "Lamps didn't respond" for 2.5 s (the prototype has a button to simulate it).
- Reduce Motion: no rubber band, no zoom or blur into the colours (a crossfade), bubbles appear in place.
- The percentage is drawn twice and masked at the fill edge: dark over the fill, white over the track.
- VoiceOver names: "Candle", "Warm white" … "Daylight", and "Pastel red", "Soft azure", "Vivid magenta" ….

### 7 · 2026-11-26 — critical round 2: F1, F2, F4; one lamp
- **Answers:** F3 rejected (one lamp); F1, F2, F4 unanswered → built, F1+F2 on one commit (they share the automation
  engine), F4 on its own.
- **Review of the new features before building:**
  - The iPhone cannot run a 30-minute fade in the background (it is woken per message for a few seconds), so the
    *watch* drives both: it stays awake through the night with the recorder and sends one step every 20 s
    (sunrise) or 3 min (wind-down). Each step is one coalesced message, so a lost one is just the next step late.
  - Nothing automatic may buzz or show an error at 6 am or at bedtime: automatic changes never trigger the failure
    note (it only shows on an open panel) and never count as yours.
  - Wind-down must never switch the lamp *on*, only soften a lamp that is on; any change by hand pauses it for the
    evening (you know better than the plan). Sunrise steps aside the same way.
  - Sunrise curve: dimming 10 → 80 % and 2200 → 4200 K, eased quadratically (slow at first, as dawn is); the alarm
    takes it to 100 % / 4500 K. The nap gets the sunrise but no wind-down.
- **F4:** in the colour wheel the crown zooms (0.42–1×): positions, bubble sizes, pan limits and the hit test all
  scale together; opening the colours parks the crown at the top of its range so the whole zoom-out is reachable.
- **Wording:** "Lamp" in the singular everywhere; the iPhone card counts bulbs.
- **New proposals:** F5–F7 (see the table).

### 8 · 2026-11-26 — endless crown, app icon (user feedback)
- **Feedback:** "isn't the crown endless?" Yes: the lamp panel bound the crown to a 0–100 range, which made the
  colour-wheel zoom need a workaround (parking the crown at the top). The crown is now read as movement only
  (continuous binding): 1 detent = 1 %, below 10 % the next turn down switches off, from off the next turn up starts
  at 10 %, and reaching 100 % or off clicks once. In the colour wheel the same movement zooms.
- **App icon** (`tools/make_icon.py` → `iOS/` and `Watch/Assets.xcassets`, preview `docs/app-icon.png`): the face's
  near-black dial with its ring of minute ticks (hour marks in sage), an ivory crescent for the night and a small
  sage crescent for the nap: two moons, two sleeps. A first version with a round nap dot read as a smiley and was
  replaced. Ticks and moons sit inside the watch's circular mask.

### 9 · 2026-11-26 — critical round 3: does it work with the iPhone app closed? Face battery cost. F6.
**Review:**
1. *Delivery with the iPhone app closed (critical; Tom asked).* Apple documents that `sendMessage` from an active
   watch app wakes the iOS app in the background ([WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession.md)),
   so daytime control works without the iPhone app open. Unknown: whether an app swiped away in the app switcher can
   be woken. Risk: night steps (sunrise, wind-down, off-when-asleep) are sent while Sage runs in the background
   with its workout session, and developers report `isReachable` false and `sendMessage` failing in exactly that
   state ([thread 83612](https://developer.apple.com/forums/thread/83612), [thread 723158](https://developer.apple.com/forums/thread/723158)).
   Not provable from here; must be measured on the watch.
2. *Silent failure at night (high).* An automatic step that failed rolled the panel back and set the failure note,
   which is meant for your own changes, and was then lost.
3. *Face battery cost (high).* The face redrew everything at 30 fps: 240 sunburst rays, a 22-ring guilloché
   (~2,000 segments), 300 track ticks and 13 bevelled indices per frame, although only the runner, the time, the
   music bars and the battery ever change.

**Changed:**
- Every lamp message is logged on the watch (time, ok/failed, background or not); the long-press menu shows the
  last contact and a full contact log, so one night answers question 1.
- Automatic steps that fail are kept quietly (no buzz, no rollback) and sent again when the app comes to the
  front; for 10 min after the alarm, raising the wrist re-sends full light if it is not on.
- The face is four layers: the dial/track and the indices/numerals are drawn once; the runner and the live layer
  (time, music, battery) follow the clock at 20 fps instead of 30.
- F6 built: off when asleep (switch in the long-press menu), two steps over 20 s so it never snaps dark.

**If the log shows night steps failing in the background:** the dependable fix is the home bridge (watch → HTTP
over Wi-Fi → bulb), which takes the iPhone out of the path; URLSession works on the watch. Tom said "not now"; it
stays the recommended fallback.

### 10 · 2026-11-26 — the lamp dims toward your real sleep times (Tom's request)
- **Request:** the lamp's dimming should use the average of recorded naps and nights, not the plan's presets.
- **Changed:** the iPhone computes the average onset and wake of the last 14 recorded naps and nights (once two
  of each exist; nights averaged on the night clock so 23:50 and 00:30 give 00:10, not noon) and sends them to the
  watch. The wind-down now dims toward your *usual* bedtime (an hour ahead, every 3 min) and, new, your usual nap
  time (20 min ahead, every minute). The menu says "Winding down to your usual bedtime 00:12".
- **Deliberately unchanged:** the plan, the face and the smart alarm. A first pass also moved the Plan tab and the
  face to the averages; reverted after Tom clarified it was meant for the lamp. The alarm's wake window must never
  follow averaged wakes: you are always woken inside it, so the average would pull it earlier night after night.
- **Tests:** `TypicalSleepTests` (midnight crossing, two-recording minimum, sync round trip).

### 11 · 2026-11-26 — "manual lower must never get brighter" (Tom) — three bugs found
- **Bug 1:** for 10 min after the alarm, raising the wrist re-sent full light even after Tom had dimmed it.
- **Bug 2:** an automatic step that failed in the background was queued and could be sent *after* a manual change,
  restoring an older, brighter level.
- **Bug 3:** any manual change, even at noon, paused that evening's wind-down (a *scheduled* wind-down was treated
  as running).
- **Fixed:** a manual change drops the post-alarm re-send and any queued automatic step; it pauses only a wind-down
  that is running now (and skips just that one); wind-down steps may only lower brightness and warm the white,
  never raise either, and leave a colour alone. A cancelled wind-down no longer clears or duplicates its successor.
- **Process:** added the quality gate above, applied from now on.

### 12 · 2026-11-26 — music bars only after "Check again" (Tom)
- **Found:** the watch's 10 s re-check read the app's scene phase captured when the loop was created; if Sage
  launched in the background that value stayed "not active" forever and the loop never checked again. Right after
  launch the watch link is also often still starting, and nothing retried soon.
- **Changed:** `AudioModel` polls by itself and reads `WKApplication.applicationState` live each time: every 3 s
  until the iPhone has answered, then every 10 s while Sage is in front.
- **Question from Tom:** the Today ring is drawn from the plan's presets, not from recorded averages → proposed as F8.

### 13 · 2026-11-26 — critical round 4 (repo public, builds back)
**Review:**
1. *Night-time crown (high).* A sleeve or the pillow can turn the crown; on the face that opened the lamp panel,
   whose crown then changes the light in the dark.
2. *Sunrise vs. you (high).* Up before the window with the lamp on bright, the sunrise's first step (10 %) would
   have dimmed it. Automation must only ever move in its own direction.
3. *Panel never closes (medium).* Control Center dismisses itself; ours stayed until X.
4. *Untested decision logic (process).* Sunrise and wind-down step maths lived inside watch-only code that the iOS
   test target cannot reach.

**Changed:**
- `LampRules` (Shared, unit-tested): a sunrise step returns nothing when the lamp is already on and at least as
  bright; a wind-down step never switches on, never raises brightness or colour temperature, leaves colours alone.
  The watch automation now uses only these.
- The crown opens the lamp only outside sleep blocks and after a firmer turn (4 detents instead of 2.5).
- The lamp panel closes after 30 s unused (not while you touch it or the colour wheel is open).
- F8 built: the Today ring draws your usual night and nap; the presets stay as a faint outline.

**Verified:** CI build + unit tests (incl. `LampRulesTests`). **Needs the watch:** crown behaviour at night,
auto-close feel.

### 14 · 2026-11-26 — critical round 5: F9, F10, VoiceOver
**Review:**
1. *Crown conflict (F9 design).* Any crown turn on the face opened the lamp, so a "long turn down" for the nap
   would have opened the lamp first. Resolved by direction: up opens the lamp (4 detents), down starts a nap only
   after 12 detents; a 1.5 s pause starts a new gesture. Still never during a sleep block.
2. *VoiceOver (bug).* The face's spoken time was computed once at the first draw and went stale.
3. *Bedside power (F10 design).* A bedside clock must cost less than the face, not more: one frame a minute, no
   runner, no dial, no overlays.
4. *Naps need the recorder.* `napNow` only finds sleep while Record is on; the face says so (with the failure
   haptic) instead of silently arming a nap watch that cannot work.

**Changed:**
- F9: crown down 12 detents → nap watch armed, `.start` haptic, "Nap: watching for sleep · Undo" for 3 s.
- F10: charging between 21:00 and 07:00 → black face with the time in deep red (#8E1B14), one frame a minute;
  the recording dot and music tap area are hidden. The prototype has a "Bedside" toggle.
- The spoken time now follows the minute.
- F9 and F10 share `SageWatchApp.swift` and went in one commit (noted, so a revert takes both).

**Verified:** CI build and tests. **Needs the watch:** crown direction feel, whether watchOS keeps Sage frontmost
on the charger (Nightstand mode takes over only with an Alarms-app alarm, which Sage does not use).

### 15 · 2026-11-27 — critical round 6
**Review:**
1. *Untested decisions (quality gate).* The crown's lamp/nap decision and the bedside rule lived in watch-only view
   code the iOS test target cannot reach.
2. *Edge bubbles too small to hit.* The fringe shrinks bubbles to 38 % (about 16 pt) and zooming out shrinks them
   further; far below a reliable finger target on a 44 mm screen.
3. *VoiceOver.* The music tap area was an unlabeled clear shape; VoiceOver users could not open Now Playing.

**Changed:**
- `FaceRules` (Shared, tested): crown up 4 detents → lamp, down 12 → nap, nothing during sleep; bedside = charging
  and 21:00–07:00. The face uses only these.
- Colour taps: every bubble's hit area is at least 30 pt across; overlaps go to the nearest centre (Swift and
  prototype).
- The music area is a VoiceOver button "Now playing" ("Pause, skip and volume").
- Proposal F11 (double tap toggles the lamp).

**Verified:** CI build and tests (`FaceRulesTests`). **Needs the watch:** colour picking at the edge.

### 16 · 2026-11-27 — critical round 7: F11 double tap
**Research:** double tap is SwiftUI's `handGestureShortcut(.primaryAction)` on a button-like control, watchOS 11+
only; the system highlights that control when the gesture fires ([Enabling double tap](https://developer.apple.com/documentation/watchos-apps/enabling-double-tap.md),
[WWDC24 10205](https://developer.apple.com/videos/play/wwdc2024/10205/)). It cannot be tried in the simulator.
**Review / decisions:**
- Nothing during a sleep block, in always-on or on the bedside clock (a pinch in sleep must not light the room).
- If the watch does not know it is home, double tap opens the lamp panel (which says why) instead of toggling from
  a stale state. Rule in `FaceRules.doubleTap`, tested.
- A note "Lamp on / Lamp off · Undo" confirms it, since an invisible button gets no visible highlight.
- *Bug caught in review:* the face note showed Undo whenever a nap was armed, so "Lamp off" would have offered an
  Undo that cancels the nap. Each note now carries its own undo action.
**Verified:** CI build and tests. **Needs the watch:** the gesture itself (watchOS 11 and a watch with double tap).

### 17 · 2026-11-27 — round 8: stabilise instead of adding
**Review:** ten builds since the first critical round and almost none of it confirmed on the watch; each new
feature on unverified ones compounds the risk. This round adds nothing new: an end-to-end audit plus a test list.
**Audit findings (fixed):**
1. While the alarm rang, the face's gestures stayed live under the wake overlay: swipe up opened the lamp panel
   over it, the crown could start a nap, long-press opened the menu. Now all stand down while ringing or testing.
2. Double tap during the alarm did nothing useful (the morning window counts as sleep). Apple's own alarms stop on
   double tap; Sage's now does too, first in `FaceRules.doubleTap` (tested).
3. A stale doc comment still said "30 fps".
**Added:** `docs/test-on-watch.md`, a 10-minute checklist of everything unverified, with the contact log as the
answer to the open background-delivery question.
**Process:** no new feature proposals until Tom has run the checklist; rounds continue with audits and fixes.

### 18 · 2026-11-27 — critical round 9 (loop resumed at Tom's request)
**Review:**
1. *Panel swapped away under the finger (high).* One failed background status check (iPhone briefly out of reach)
   flipped "home" to false and replaced the open panel with the "not reachable" view mid-gesture.
2. *Frozen-looking wait.* "Checking…" was static text.
3. *Prototype parity.* The connection states could not be reviewed in the prototype.

**Changed:**
- `LampRules.showControls` (tested): the controls stay for 2 min after the lamp last answered, with a small
  "Reconnecting…" pill that retries; only a lasting drop shows the reason and Retry.
- The waiting view shows a spinner; the reason view keeps the icon, the plain-words problem and Retry.
- Prototype: a "Connection" selector shows at home / short drop / unreachable.
- Proposals F12 (night light from the bedside clock) and F13 (bedtime tap).

**Verified:** CI build and tests. **Needs the watch:** the reconnect pill in a real drop.
