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
| F12 | **Night light from the bedside clock:** on the charger at night, turning the crown sets the lamp to a dim red night light (5 %), for getting up without waking fully; turning back down switches it off. Never bright | built (round 10, no answer; 10 % is the WiZ minimum) |
| F13 | **Bedtime tap:** at your usual bedtime, if the lamp is still bright and wind-down is off, one quiet tap on the wrist with "Bedtime" (no sound); nothing if the lamp is already dim or off | built (round 10, no answer) |
| F14 | **Try the sunrise:** a "Try sunrise" button in the long-press menu plays the whole wake-up light in 60 s (10 % candle → 80 % daylight → full), so you can see and judge it without waiting for a morning; any touch of the lamp stops it | built (round 12, no answer) |
| F15 | **Walk direction in recordings:** record the compass heading once a second (device motion, magnetic north) alongside the barometer, so walks get a direction and length; with floor changes from the barometer, a change of room shows up in the data (for counting work like beds). Small battery cost; compass is disturbed near metal (bed frames), so direction changes, not absolute bearings, are used | built (Tom asked for full position tracking) |
| F16 | **Arrival light:** when you come home after dark and the lamp is off, it comes on warm (60 % 2700 K; 25 % 2200 K within an hour of bedtime). "Away" = the iPhone answered "no bulb" at least twice ≥ 20 min apart, and the lamp answers within 30 min of the last one. Never on a lamp that is on, in a sleep block, under the open lamp panel, or within 10 min of your own switch-off. Toggle "Arrival light" | built (round 23, no answer) |
| F17 | **Nap length on the crown:** after the long turn down starts a nap (F9), the note shows its length ("Nap · up to 100 min") and further turns change it in 5-min steps (4 detents each, 20–130 min, up = longer) while the note is up; each step keeps the note 3 s more | built (round 23, no answer) |
| F18 | **Battery guard for the alarm:** at your usual bedtime, with Record on, below 30 % and not charging (the recorder and smart wake may not last the night): one quiet tap and the note "Charge for the alarm", once per night; nothing on the charger | built (round 25, no answer) |
| F19 | **Recording stopped:** Record is on but no motion was written for 10 min (a crash, a revoked permission, a session that ended): one tap and the note "Recording stopped" with Restart (8 s). Not in the first 2 min of a run; during a sleep block it waits until the block ends, so it never taps you awake | built (round 25, no answer) |
| F20 | **Earlier wind-down after a short night:** when the last recorded night was over an hour shorter than your usual (and it was last night, ended < 20 h ago), the night's wind-down starts 30 min earlier (90 min lead); naps unchanged; lamp only, the plan and alarm are unchanged | built (round 26, no answer) |
| F21 | **Recent colours in the wheel:** the three colours you chose last carry a small white dot (VoiceOver: "recent"); the wheel opens on the middle of the current and recent colours when they all fit in the full-size centre, else on the current one | built (round 27, no answer) |
| F22 | **Time-aware switch-on:** switching the lamp on from off (tap, double tap, VoiceOver) after dark brings back your own last evening light, in daylight your last daytime one; remembered only from your changes that reached the lamp, never the bedside night light or an automation; toggle "Light by time of day" | built (round 28, no answer) |
| F23 | **Arrival in your evening light:** the arrival light (F16) comes on at your remembered evening light (F22) instead of a fixed 60 % (only with "Light by time of day" on), and still 25 % 2200 K inside the wind-down | built (round 29, no answer) |
| F24 | **Double tap answers the note:** while a note with a button shows (Undo, Restart), double tap presses that button instead of toggling the lamp, as watchOS's double tap presses the primary button on screen; a ringing alarm still comes first; not in always-on (the note is not seen there) | built (round 30, no answer) |
| F25 | **Lamp panel closes with the wrist:** lowering the wrist (the app leaves the front) closes the lamp panel, so the next raise shows the face, as Control Center does; never while a finger is on it (then right after the touch ends) | built (round 31, no answer) |
| F26 | **Night cap:** between your usual bedtime and wake (learned night), the slider and the crown stop at 30 % with a click and the stretch of the real top; a second push from the cap (a new drag starting there, or a crown turn after resting there ½ s) goes higher; switching on at night comes on at most 30 %; a light set brighter before is never pulled down; night changes are not remembered as the evening light (F22); toggle "Night cap" | built (round 42, no answer) |
| F27 | **Adaptive white (like Apple Home's Adaptive Lighting):** while the lamp is on in white, its white follows the day: 2200 K before sunrise, 2700 K at sunrise rising to 4000 K at solar noon, back to 2700 K at sunset; ≤ 300 K steps every 4 min, brightness untouched, never on a colour. Evening and night only ever warmer (after the wind-down it stays candle-warm). Steps aside for the sunrise, its preview, the wind-down and the minutes after the alarm; a white or colour you pick pauses it until the lamp is next switched off; toggle "Adaptive white" | built (round 47, no answer) |
| F28 | **One switch for position:** turning Track position on (or off) on either device turns it on (or off) on the other; the watch sends with transferUserInfo (queued, arrives later too), the iPhone in the application context (arrives even if the watch app is not running); the newer change wins, so a late message never undoes a newer choice. The iPhone's switch now reads "Track position (iPhone and watch)" | built (round 54, no answer) |

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

### 19 · 2026-11-27 — critical round 10: F12 night light, F13 bedtime tap
**Design review before building:**
- WiZ dimming cannot go below 10 %, so the night light is deep red (255, 28, 0) at 10 %, not the proposed 5 %.
- `WKHapticType.notification` can play a tone; at bedtime that is unwelcome, so F13 uses two `.click`s.
- No nagging: F13 taps only when wind-down is off; if wind-down is on (running, or paused by your own change)
  you have already chosen. It asks the lamp fresh before deciding, so a cached state never taps.
- A white note pill would be the brightest thing on the red bedside clock: notes are red there too.
**Changed:** F12 (`FaceRules.bedsideCrown`, tested): crown up on the bedside clock → night light with Undo, crown
down → lamp off; "Lamp not reachable" if it cannot be reached. F13 (`LampRules.bedtimeTap`, tested): at the usual
night bedtime, two clicks and "Bedtime · lamp still bright"; switch in the long-press menu. Each on its own commit.
**Verified:** CI build and tests. **Needs the watch:** whether watchOS lets the crown wake the bedside clock and
whether background clicks are felt at bedtime.

### 20 · 2026-11-27 — critical round 11
**Review:**
1. *Night light left on all night (high).* Get up at 3 am, night light on, back to bed: "off when asleep" only
   fires once per night (at the first sleep onset), so the room stayed red until the sunrise.
2. *Undo too small.* The note's Undo was 13 pt text with no padding; half-asleep fingers miss it.
**Changed:**
- The night light switches itself off after 15 min, but only if the lamp still shows it (dim red at 10 %); turned
  up or changed to a white, it is yours and stays (`LampRules.nightLightExpired`, tested). The note says
  "Night light · 15 min".
- Undo is a ~44 × 32 pt target.
- Proposal F14 (try the sunrise in 60 s).
**Verified:** CI build and tests. **Needs the watch:** the 15-min timeout while Sage is in the background at night
(same background-delivery question as the other night steps; see the contact log).

### 21 · 2026-11-27 — critical round 12: F14 try the sunrise
**Design review before building:**
- A preview must leave the lamp exactly as it was; a 60 s test that leaves it at full brightness is a bug.
  `LampRules.restore` (tested) puts back off / the white / the colour.
- Touching the lamp (or the crown) during the preview stops it and keeps your setting: no restore after.
- It must start at the dawn end even when the lamp is already bright, otherwise the "never dim a brighter lamp"
  rule would leave nothing to see; it then follows the real curve (`LampRules.sunrise`), 2 s steps.
**Changed:** long-press menu → Lamp → "Try sunrise (60 s)": 10 % candle → 80 % daylight in 60 s, full light 5 s
(as the alarm), then back. The prototype has the same button. Real sunrise and preview never run together.
**Verified:** CI build and tests. **Needs the watch:** how the steps look on the real bulb (2 s step rate over the
iPhone link).

### 22 · 2026-11-27 — position tracking (Tom) and critical round 13 on it
**Tom's request:** record where he goes all day, as accurately as possible, in 3D (stairs), with GPS when available
and other methods otherwise, using the iPhone and the watch. Expectation set honestly: height ~10–25 cm (barometer),
floors reliable, outdoors a few metres (GPS), indoors room-level by dead reckoning; 10 cm horizontal indoors would
need the iPhone's camera (ARKit) or installed beacons/UWB anchors.
**Built (build 78):** Track position on the watch (GPS, compass/orientation 10 Hz via magnetic-north device motion,
steps/floors, absolute altitude, plus the existing barometer) and on the iPhone (the same streams plus its own
barometer, background location). `tools/track3d.py` fuses both into one 3D path (barometer height pinned to
GPS/absolute altitude, Kalman + RTS smoother over GPS and step/compass dead reckoning, pocket heading offset learned
from GPS course). On a synthetic day with a known path: height median 0.13 m, floors 100 %, outdoors 0.6 m (clean
GPS noise, optimistic), indoors 3.9 m after 14 min.
**Round 13 review of it (for a whole working day):**
1. *Silent end on the iPhone (critical).* iOS can terminate a background app; standard location updates do not
   relaunch it, so the recording would just stop. Now also significant-location-change monitoring (relaunches
   Sage) and the tracker is created in the app delegate, so it resumes even on a background launch.
2. *Flat battery loses the rest of the day (high).* Below 20 % (not charging) GPS drops to ~10 m accuracy on both
   devices; back to best above 30 % or on the charger (`PositionRules.gpsMode`, tested; the gap avoids flapping).
   Barometer, steps and compass keep running. The menu / Data tab show when it is saving.
3. *Process:* do not install new builds during a recording day (a reinstall restarts the app and leaves a gap).
**Verified:** CI build and tests. **Needs a real day:** background GPS on the watch, battery, the real 3D path.

### 23 · 2026-11-27 — round 14: the 3D viewer (no app change on a recording day)
- **Decision:** no app changes this round; Tom may be recording today, and every app change means a build he should
  not install mid-day. The round prepares tonight instead.
- **Added:** `track3d.py --html` writes `track.html`, a self-contained interactive 3D viewer (template
  `tools/track_viewer.html`, no libraries): drag to rotate, scroll/pinch to zoom, height exaggeration (floors are
  small next to walking distances), colours per floor, a time slider moving a marker along the day with time, floor,
  height and accuracy, summary tiles (walked distance, floor changes, minutes indoors and per floor). Tested on the
  synthetic day and published as "Sage Day Path".

### 24 · 2026-11-27 — round 15: the 3D path under real-world conditions (still no app change)
Tested `track3d.py` on four edge cases built from the synthetic day: watch only (iPhone left behind), no GPS at all,
an 8-minute gap in all data, and GPS from both devices at once. All run and give plausible numbers.
**Found and fixed:**
1. *Silent false orientation.* Without a GPS walk the pocket/wrist heading offset cannot be learned; the path's
   shape is right but it may be rotated. The tool now says so (and that positions are relative without any fix)
   instead of presenting a possibly rotated map as fact.
2. *Gaps drawn as walks.* Seconds with no sensor within ±30 s are marked "gap": the viewer leaves a break, the HUD
   says "no data", the summary counts the minutes.
**Verified:** the four cases. **Needs a real day:** everything about real sensor noise (compass near metal, GPS
multipath indoors).

### 25 · 2026-11-27 — round 16: find a broken recording while it can still be fixed (no app change)
- **Review:** the biggest risk of the position day is not tonight's processing but discovering tonight that a
  stream was never recorded (a permission, a paused stream, an uncalibrated compass), when the day is lost.
- **Added:** `tools/check_export.py`: for a short export taken during the day, lists per device whether GPS,
  compass, steps/floors, barometer and absolute altitude are present, at the right rate (compass ~10/s), with gaps
  over 2 min, GPS accuracy, compass validity (heading -1 = uncalibrated) and the height range. Tested on a good, a
  deliberately broken (gaps, dead compass) and an old export without position data; it flags each problem.

### 26 · 2026-11-27 — round 17: the phone gets taken out of the pocket (no app change)
- **Review:** track3d learned one pocket-heading offset for the whole day. Every time the phone is taken out and put
  back, that offset changes, and every indoor stretch after it would be drawn rotated.
- **Measured:** a synthetic day with one re-pocketing (35° → 110°): one offset for the day blends to 72° and puts the
  path **126–212 m** off.
- **Changed:** re-pocketings are found from the phone's orientation (its z axis turning > 45° within 10 s); each
  period between them learns its own offset from its own GPS walks; a period without a GPS walk borrows the nearest
  one and the summary warns about it. Not applied to the watch (a wrist turns constantly).
- **Result:** the re-pocketing is found at minute 12, offsets 35.0° / 109.9° (true 35 / 110), errors back to 0.6 m
  outdoors / 3.9 m indoors; the normal day is unchanged.

### 27 · 2026-11-27 — round 18: weather must not climb stairs (no app change)
- **Review:** floors came from absolute barometer height. Weather drifts the barometer 1–2 m per hour; outdoors GPS
  pins it, but a long indoor stretch without GPS drifts freely.
- **Measured** (`tools/synth_indoor.py`: 4.4 h, 4 h indoors, 0→2→1→0 floors, 1.8 m/h drift): **78** floor changes
  instead of 4, floor right only **37 %** of the time.
- **Changed:** floors come from stair/lift events: climbing shows as ≥ 1.2 m/min (drift is ~40× slower); an event
  with ≥ 2.2 m change counts as round(change / 3 m) floors; between events the floor stays fixed (floor 0 = where
  the recording started).
- **Result:** exactly 4 changes, floor right 100 % (1 min off, on the stairs themselves); the normal day 97 % (the
  3 % are the seconds on the stairs, where "which floor" is ambiguous). All earlier edge cases still run.

### 28 · 2026-11-27 — round 19: an automated regression test for the 3D path (no app change)
- **Review (quality gate):** track3d had seven test days, checked only by hand; a later change could quietly undo
  an earlier fix. Also open from round 18: a climb at the edge of a data gap made the height change NaN and was
  dropped silently.
- **Added:** `tools/test_track3d.py` builds every synthetic day and checks limits: floors, floor-right share, outdoor
  and indoor error, heading offsets per pocket period, gap minutes, warnings, watch-only. Run after every change.
- **Found by the test on its first run:** a climb that spans a data gap (starts before, ends after) was not counted
  (2 floor changes instead of 4). Fixed: the heights on both sides of a gap are compared and any floors in between
  counted; climbs at a gap edge use the nearest valid heights within a minute.
- **Result:** 13/13 checks pass.

### 29 · 2026-11-27 — round 20: "it should see when I go up the stairs" (no app change)
- **Added:** every floor change is an event in the result and the viewer: time, from → to, and **stairs or lift**
  (steps taken while the height was changing). Apple's step counter also counts floors; when it disagrees with the
  barometer the summary warns (lifts are not counted there).
- **Found by the regression test:** a lift ride was labelled "stairs". Two causes, both fixed: the event window was
  padded by 30 s (you walk straight out of a lift), and the 1-minute climbing rate smears ~30 s past the ride.
  The classification now uses only the steep part of the height change (10 s rate, above half its peak).
- **Test:** the long indoor day now has a lift ride; the regression test checks 0→2 stairs, 2→1 stairs, 1→0 lift.
  14/14 pass.

### 30 · 2026-11-27 — round 21: the export tonight must not fail (iPhone app change; install after recording)
- **Review:** the last step between the recorded day and the 3D path is the export. There was no "Today" range (the
  choice would have been "Last 24 hours", including last night), and raw motion is on by default: 24 h of 50 Hz is
  ~4 million lines, >100 MB — slow, risky on the phone, awkward to send, and not needed for the path.
- **Changed:** ranges "Last hour" (for the health check) and "Today" at the top; choosing either switches raw
  motion off (it can be switched back on). The Position section has "Export today's position data" (today, no raw).
  Tested: the two new ranges (`testTodayAndLastHourRanges`).
- **Process:** this is an iPhone app change on a recording day: install only after the day's recording ends
  (reinstalling restarts the app and leaves a gap).

### 31 · 2026-11-27 — round 22: the lamp panel under failure (watch app change; install after recording)
- **Review (failure states, concurrency):**
  - `busy` was one flag set and cleared by every message. A status check and a change can be out together; the
    first to finish cleared it, so "Checking…" stopped spinning while the other was still waiting (and the panel
    looked frozen or showed a stale error).
  - "Reconnecting…" checked once when it appeared. If that one check failed, the pill kept saying it was
    reconnecting for up to 2 min without trying — the text promised something the code did not do.
  - The 30 s idle close lived on the controls only. The "not reachable" screen never closed itself and kept the
    app in front (battery, and the face hidden) until dismissed by hand.
  - VoiceOver adjustments and actions did not count as use, so the panel could close in the middle of them.
  - Two failures within 2.5 s: the first note's timer hid the second note after a fraction of its time.
- **Changed (Swift and prototype):** `busy` counts messages in flight; "Reconnecting…" retries every 8 s and never
  starts a check while one is out (`LampRules.retryReconnect`); the idle close covers both views and is a tested
  rule (`LampRules.idleClose`); VoiceOver use and Retry reset the idle timer; a second failure restarts the note's
  2.5 s. Prototype: the failure timer restarts, and the controls show the checks sent while reconnecting.
- **Tests:** `testPanelClosesWhenIdleButNeverUnderAFinger`, `testReconnectRetriesWithoutPilingUp`.
- **Verified:** rules by unit tests (CI), prototype JS parses. **Needs the real watch:** how often a real drop
  recovers within the 2 min grace with 8 s retries, and that the idle close is not felt as too early.
- **Proposed:** F16 arrival light, F17 nap length on the crown (built next round if unanswered).

### 32 · 2026-11-27 — round 23: F16 and F17 built (unanswered → approved; watch app change, install after recording)
- **F17, nap length on the crown** (own commit): the nap note shows the length; 4 crown detents per 5 min, 20–130
  min. The chosen length is this nap's only (the settings stay), persisted so a relaunch keeps it, cleared by
  Undo, by a new nap and once sleep is found. The wake window keeps the usual width but never opens before half the
  nap (`AlarmSettings.napWindow`, tested: 100 → 70–100, 60 → 30–60, 20 → 10–20).
  - **Review findings fixed before commit:** the turn that started the nap carries on for a moment and would have
    shortened it at once — editing starts 0.6 s after the start; any other note ends the editing, so a crown turn
    after "Lamp on" can never change a nap.
- **F16, arrival light** (own commit): sunrise/sunset from a rough position (`Sun`, NOAA approximation, tested for
  Zürich in November and June, midnight sun, and the no-position fallback 17:00–07:00). The watch keeps its last GPS
  fix rounded to 0.1° (~10 km), on the watch only.
  - **Review findings fixed before commit (the user always wins):**
    1. An iPhone out of Bluetooth range in another room must not look like leaving: only the iPhone's own answer
       "no bulb replied" counts as away; an unreachable iPhone never does.
    2. One flaky "no bulb" at home, then no check for an hour, would have looked like coming home and switched on a
       lamp you had switched off. Away now needs two such answers ≥ 20 min apart, and the arrival must follow the
       last one within 30 min.
    3. Opening the panel at the door to switch on, while the arrival also switched on, would make your tap toggle
       it straight back off: no arrival while the panel is open.
  - Never touches a lamp that is on, never in a sleep block, never within 10 min of your own switch-off.
- **Prototype:** the face preview has "Start nap" with the note; the scroll wheel sets the length as the crown does
  (same steps, ends and 0.6 s guard). F16 has no visual part beyond the lamp coming on.
- **Verified:** rules by unit tests (CI). **Needs the real watch:** whether the watch asks the lamp often enough
  while you are out for "away" to be proven (it asks when the app comes to the front), and how the 4-detent step
  feels on the crown.

### 33 · 2026-11-27 — round 24: what F16/F17 left out (watch app change; install after recording)
- **Review of last round's features:**
  - F16 switched the lamp on with nothing on the face and no way back: an automation that switches a light on
    must say so and be undoable on the spot. The menu's "Now" row also kept "Welcome home" for the rest of the
    evening.
  - F17's chosen length was visible for 3 s only; after the note there was nowhere to check it.
  - The face's notes vanish in 3 s, before VoiceOver reaches them by swiping: VoiceOver users never heard "Nap ·
    up to 90 min", "Lamp on" or "Welcome home".
- **Research:** Apple's Feedback guidance for watchOS asks apps to avoid indeterminate progress indicators (people
  glance; show content). The "Reconnecting…" pill had a spinner over controls that work.
- **Changed:** "Welcome home · lamp on" note with Undo (Undo counts as your own switch-off, so nothing switches it on
  again for 10 min); "Now" clears after 10 min (cancellable, so a second arrival is not cleared early); the menu
  shows "This nap: up to N min" while a nap waits for sleep; every face note is announced to VoiceOver as it
  appears; the pill shows a static antenna symbol instead of a spinner (Swift and prototype). The "Checking…"
  spinner stays: with no state known yet there is no content to show instead.
- **Verified:** CI build. No new decision logic (the arrival rule is unchanged and tested). **Needs the real
  watch:** that the announcement does not cut into VoiceOver reading something else.
- **Proposed:** F18 battery guard for the alarm, F19 recording-stopped warning.

### 34 · 2026-11-27 — round 25: F18 and F19 built (unanswered → approved; watch app change, install after recording)
- **F18, battery guard** (own commit): `WatchGuard` checks once a minute; within 5 min after the usual night bedtime,
  `FaceRules.batteryGuard` (Record on, not charging, < 30 %, unknown level quiet; tested) gives one click and
  "Charge for the alarm", once per night.
- **F19, recording stopped** (own commit): the recorder counts motion every 10 s; no change for 10 min with Record
  on is a stall (`FaceRules.recordingStalled`, tested), reported once until samples move again, with Restart.
  `Recorder.restart()` ends the run and starts a new one when the end has gone through (new files; nothing
  recorded is lost).
  - **Review findings fixed before commit:** a stall in the night would have tapped you awake (only the smart wake
    may) — it now waits for the end of the sleep block; a warning with an action needs longer than a 3 s
    confirmation — it stays 8 s, and the menu's Record switch remains the way back after that; F18 and F19 are
    split so each can be reverted alone (the haptic lives with its own feature).
- **Prototype:** the face preview's note takes any text and button (Undo, Restart or none) and duration; buttons
  show the F18 and F19 notes.
- **Verified:** rules by unit tests (CI). **Needs the real watch:** that the minute check keeps running in the
  background through the night (the bedtime tap relies on the same), and that a real stall (e.g. revoking Motion
  access) is found within ~11 min.
- **Proposed:** F20 earlier wind-down after a short night.

### 35 · 2026-11-27 — round 26: F20 built (unanswered → approved; watch + iPhone data change, install after recording)
- **F20** (own commit): `TypicalSleep` now carries the newest night's length and end (sent with the averages, old
  saved data decodes without them); `LampRules.windDownLead` adds 30 min when that night was > 60 min shorter than
  the usual night and ended < 20 h ago (tested: short, slightly short, nap, an old night, no data). The bedtime
  itself is unchanged, so the bedtime tap and the battery guard keep their times; the "Now" row says "Winding down
  early (short night)".
- **Review findings fixed:** the arrival light (F16) decided "close to bedtime" with a hard-coded 60 min, so after a
  short night it would come on at 60 % inside a running 90-min wind-down, which then pulls it down again — the
  light jumps up and creeps down. It now asks whether it is inside the actual wind-down lead (`inWindDown`).
  The lamp menu's footer described three of the six automations; it now names all of them and says that your own
  change always wins.
- **Prototype:** no visual change this round (F20 only changes timing); not republished.
- **Verified:** rules by unit tests (CI). **Needs real nights:** the iPhone must have analysed last night before
  the evening for the watch to know it was short (it sends the averages after each sync).
- **Proposed:** F21 recent colours in the wheel.

### 36 · 2026-11-27 — round 27: F21 built (unanswered → approved; watch app change, install after recording)
- **F21** (own commit): recents are cell ids, newest first, three at most (`LampRules.recents`, tested: first,
  move to front, cap). The wheel's opening centre is `LampRules.openCentre` (tested): the middle of the current and
  recent colours when every one of them stays inside the full-size centre zone, else the current colour (as before),
  else the recents, else the wheel's middle. Marked with a 7 pt white dot with a faint dark edge (visible on whites
  and vivid colours alike); the set colour keeps only its ring.
- **Review findings fixed before commit:** the first version read the recents from UserDefaults inside each bubble's
  body — 61 reads per frame while panning on a watch. They are now read once when the wheel opens. Recording a
  recent is part of choosing (the same path for touch and VoiceOver).
- **Prototype:** the same rules, dot and opening centre; recents kept while the page is open.
- **Verified:** rules by unit tests (CI), prototype JS parses. **Needs the real watch:** whether the dot reads at
  the fringe's smallest bubble size (it scales with the bubble).
- **Proposed:** F22 time-aware switch-on.

### 37 · 2026-11-27 — round 28: F22 built (unanswered → approved; watch app change, install after recording)
- **F22** (own commit): two memories, evening (dark here, from the sunset of the rough position) and day.
  `LampRules.memory(of:)` keeps dimming and white or colour of a lamp that is on, never the night light (tested);
  `LampRules.switchOn(memory:)` is "on" plus that light, or just "on" with nothing remembered (tested). The memory is
  written when a change you made has been confirmed by the lamp and nothing newer is waiting, so a failed change or
  a half-way slider value is not remembered; automatic changes (sunrise, wind-down, arrival) never are.
- **Review points:** off stays a plain off (Undo after a double-tap on works as before); switching on during the
  wind-down hour is your own change, so it pauses the wind-down as any change of yours does; the arrival light now
  uses the same `Sun.darkHere` as F22, so both agree on when evening starts.
- **Prototype:** "After dark" switch; tap on brings back the remembered light for it; drags, the crown and colour
  picks are remembered (not the night light).
- **Verified:** rules by unit tests (CI), prototype JS parses. **Needs the real watch:** whether bringing back the
  evening light feels right or surprising the first evenings.
- **Proposed:** F23 arrival in your evening light.

### 38 · 2026-11-27 — round 29: F23 built (unanswered → approved; watch app change, install after recording)
- **F23** (own commit): `LampRules.arrivalLight` takes the evening memory; outside the wind-down it returns
  `switchOn(memory:)` of it, inside the wind-down still 25 % 2200 K (tested both). Without a memory, or with "Light by
  time of day" off, it stays the warm 60 %.
- **Review:** a remembered evening light can be a bright colour; that is your own last evening choice, so it is
  the right light to come home to; the wind-down rule still wins near bedtime, so it never comes home bright then.
- **Prototype:** no visual change (the arrival has no screen of its own beyond the note); not republished.
- **Verified:** rule by unit tests (CI). **Needs the real watch:** as F16.
- **Proposed:** F24 double tap answers the note.

### 39 · 2026-11-27 — round 30: F24 built (unanswered → approved; watch app change, install after recording)
- **F24** (own commit): `FaceRules.doubleTap` gained `noteButton`, checked right after a ringing alarm (tested: the
  note's button wins over the lamp, also on the bedside clock; the alarm wins over the note; nothing in always-on).
  The face passes "a note with a button is up"; the action is the same closure as tapping the button, with the
  click haptic.
- **Review:** after a double tap switched the lamp on, the "Lamp on" note's Undo is the toggle back, so a second
  double tap within 3 s still does what a double tap did before. On the bedside clock a double tap used to do
  nothing; with a night-light note up it now undoes the night light, which is what the visible button says.
- **Prototype:** has no double tap; not republished.
- **Verified:** rule by unit tests (CI). **Needs the real watch:** double tap is watchOS 11+ on watches that have it.
- **Proposed:** F25 lamp panel closes with the wrist.

### 40 · 2026-11-27 — round 31: F25 built, and a stuck touch found (watch app change, install after recording)
- **F25** (own commit): the panel watches the scene phase; leaving the front closes it (`LampRules.closeOnWristDown`,
  tested). If a finger was still down, the close happens as soon as that touch has ended.
- **Found while building it (pre-existing):** a touch the system cancels (a notification, the wrist going down
  mid-drag) never reaches the gesture's onEnded, so `touching` stayed true for good: the 30 s idle close never
  fired again and the crown ignored brightness changes until the panel was reopened. Now a `@GestureState` that
  resets by itself detects the cancel; if onEnded has not run 150 ms after it, the touch is ended without counting
  as a tap (a cancel must never switch the lamp), the press look springs back, the level a drag had set stays.
  `release()` runs once per touch.
- **Prototype:** has no scene phase or system cancels; not republished.
- **No new proposal this round:** the list has 25 entries, all built or rejected; the next rounds go back to
  reviewing what is there, and a proposal comes when there is a real gap.
- **Verified:** rule by unit tests (CI). **Needs the real watch:** the order of onEnded and the gesture-state reset
  (the 150 ms wait makes either order safe), and that a lowered wrist closes the panel without a flash.

### 41 · 2026-11-27 — round 32: the face's note, measured (watch app change, install after recording)
- **Review:** the note pill now carries nine different messages from six features, and nobody had measured it.
  At 13 pt semibold, "Welcome home · lamp on" plus the 44 pt Undo button and the padding is ~200 pt; the 44 mm
  screen is 184 pt (40 mm: 162 pt). SwiftUI wraps the text to two lines inside a capsule — it looks broken.
  In always-on the pill and its button stayed up, bright over the dimmed face, with a button that cannot be
  pressed there. VoiceOver read the button as a bare "Undo" or "Restart". And the prototype drew the note at half
  size: the face preview is 2 px per watch point (368 px for 184 pt), the note was written in points.
- **Changed:** the note text is one line and shrinks to 75 % before it would wrap; the button never shrinks
  (`fixedSize`); texts shortened ("Welcome home", "Bedtime · lamp is bright"); no note in always-on (F24's double
  tap already ignored it there); the button reads "Undo, Welcome home"; a merged comment from round 25 cleaned up.
  Prototype: note at the right scale (26 px text, 88 x 64 px button), the same shrink-to-fit, buttons for the
  arrival and bedtime notes.
- **Verified:** CI build; prototype JS parses. **Needs the real watch:** the shrink on the 40 mm screen for the
  longest note ("Nap · up to 100 min" + Undo).

### 42 · 2026-11-27 — round 33: way back from the colours (watch app change, install after recording)
- **Research:** the watchOS 10 Home app: tapping an accessory toggles it, more control sits one level deeper
  behind its own button — the same split as ours (tap = on/off, slider, colours behind a long press).
- **Review:** in the colour wheel the corner ✕ closed the whole panel, while the only way back to the slider was
  tapping empty space between bubbles (not discoverable, and the wheel is mostly bubbles). One level deeper should
  have a back button in the corner, as every watchOS navigation does. The crown zoom also stopped silently at its
  ends, unlike the slider, which clicks.
- **Changed (Swift and prototype):** the corner button is a back chevron while the colours are open (closes them,
  VoiceOver "Back to brightness") and ✕ on the slider; the icon swaps with the symbol transition. The crown zoom
  clicks once when it reaches all-61 or full size.
- **Verified:** CI build; prototype JS parses. No new decision logic. **Needs the real watch:** that the toolbar
  button's swap reads as back, not as a different close.

### 43 · 2026-11-27 — round 34: three ways automation could still beat you (watch app change, install after recording)
- **Review (user vs automation, every state), three findings:**
  1. "Off when asleep" fades in two steps 20 s apart. A change you made in between was overwritten by the second
     step: the lamp went off although you had just set it — you were obviously awake.
  2. A failed automatic step waits to be retried when the app comes to the front. A newer *automatic* step did not
     replace it: an "off, you fell asleep" that failed during a nap would be sent after the alarm's full light, as
     soon as you raised the wrist — the room goes dark right after waking. The same hole existed for a step that
     failed while a newer one was already queued behind it.
  3. Sleep onset is found after the fact. If you changed the lamp yourself after the moment the watch later calls
     "fell asleep" (reading in bed, lying still), the lamp still went off.
- **Changed:** the second asleep step is a task that any change of yours cancels; every change, yours or
  automatic, drops an older deferred step, and a failed step is deferred only if nothing newer is waiting; the
  asleep fade checks `LampRules.offWhenAsleep(onset:lastUserChange:)` (tested) with the onset the detector found.
- **Prototype:** automation only; no visual change, not republished.
- **Verified:** rule by unit tests (CI). **Needs real nights:** the contact log shows whether deferred steps are
  still being sent, and when.

### 44 · 2026-11-27 — round 35: text size and what VoiceOver hears on the face (watch app change, install after recording)
- **Research:** Apple's typography guidance: use the system text styles, which follow Dynamic Type and Bold Text;
  default sizes differ per watch size; fixed sizes truncate or clip at larger settings.
- **Review:** every small text outside the clock was a fixed point size (the note 13/14 pt, the lamp pills 12 pt,
  the "not reachable" text 13 pt) and ignored the wearer's text size. VoiceOver on the face heard only the time:
  the battery bar, the recording dot and the sleep face said nothing — a VoiceOver user could not know the battery.
- **Changed:** note, pills and lamp messages use footnote / caption styles; the note and the failure pill follow
  the text size up to xxLarge (beyond that one line no longer fits the 40 mm pill; it still shrinks 75 % first).
  The face's VoiceOver element reads e.g. "12:41, battery 78 percent, charging, recording, sleep time".
  The clock digits stay drawn at their fixed design size (they are the face, and already large).
- **Prototype:** default text size only, no visual change; not republished.
- **Verified:** CI build. **Needs the real watch:** the note at the largest allowed size on 40 mm, and VoiceOver
  reading order on the face.

### 45 · 2026-11-27 — round 36: the face draws what moves, when it moves (watch app change, install after recording)
- **Review (battery):** the face's live layer — four glyph paths with two shadow copies each, the music bars and
  the battery bar — was redrawn 20 times a second all minute. The time only changes in the first 0.75 s of a minute
  (the digit morph); the music bars move only while something plays; the battery bar almost never. That is ~1,200
  full redraws a minute for under 20 that show anything new.
- **Changed:** the time and battery layer runs on `FaceRenderer.MorphSchedule`: 20 fps for the first 0.8 s of each
  minute, then nothing until the next minute (tested: in the window, after it, mid-minute, under 20 frames per
  minute; a hair before the minute counts as on it, so floating point can never produce a burst of tiny steps).
  The music bars are their own layer at 20 fps, present only while something plays. The runner (the seconds) stays
  at 20 fps, it is the one thing that always moves. The battery bar still eases, in the morph frames.
- **Prototype:** draws everything every frame on a computer; the layer split is performance only and changes no
  pixel, so it is not mirrored.
- **Verified:** schedule by unit tests (CI). **Needs the real watch:** battery over a day compared with before
  (Battery in Settings shows Sage's share).

### 46 · 2026-11-27 — round 37: the menu's lamp section, one screen instead of four (watch app change, install after recording)
- **Review:** the long-press menu's lamp section had grown to six toggles, a button, two rows, a link and a
  six-paragraph footer — four screens of crown scrolling, with each automation explained far from its switch.
  The disabled "Try sunrise" (when the lamp cannot be reached) gave no reason.
- **Changed:** the lamp section shows what matters at a glance — Now, Last contact, "Automations: 5 of 6 on",
  Try sunrise, Contact log — and a one-line footer (your change always wins; or why Try sunrise is off). The six
  toggles are on their own "Automations" page, each with a one-line description under its title, as watchOS
  settings lists do, and the closing note about the iPhone and the contact log.
- **Prototype:** has no menu; not republished.
- **Verified:** CI build. No new decision logic.

### 47 · 2026-11-27 — round 38: the crown at the speed you turn it (watch app change, install after recording)
- **Research:** Apple's Digital Crown guidance: update the interface to match the speed people turn the crown;
  pickers change values as it turns. No numbers are published; Apple's own scrolling gains with angular velocity.
- **Review:** the lamp's crown moved exactly 1 % per detent, so 10 → 100 % took ~90 detents (about three full
  turns) — precise, but slow for the common "full light" turn. In the colour wheel VoiceOver walked the 61 bubbles
  in ring order, so the colour that is set and the recent ones (F21) could be 50 swipes away.
- **Changed:** `LampRules.crownStep` (tested): 1 % per detent when detents are ≥ 120 ms apart (slow, precise),
  rising to 4 % at ≤ 30 ms (a spin covers the range in under a turn); the ends, the 10 % floor and the off detent
  behave as before. VoiceOver order in the wheel: the set colour, then recents, then the whites, then the hues.
  Prototype: the scroll wheel gains the same way.
- **Verified:** rule by unit tests (CI); prototype JS parses. **Needs the real watch:** that the 120 / 30 ms
  thresholds feel natural with the crown's real detent rate.

### 48 · 2026-11-27 — round 39: the device checklist catches up (docs only, no new build)
- **Review (process):** seventeen rounds and ten features since the on-watch checklist was last written; it still
  described the old crown (1 % only), the old note text, and had nothing for F16–F25 or the user-wins fixes. Every
  round ends "needs the real watch" — the checklist is where that debt is paid, so it must be complete.
- **Changed:** `docs/test-on-watch.md` rewritten for build 105: notes (one line, always-on, double tap, VoiceOver),
  crown speed, colour wheel back / recents / zoom clicks, light by time of day, wrist-down close, reconnect, the
  cancelled-touch case, the menu's Automations page, nap length on the crown, an evening for the arrival light
  (including the must-never case: an hour at home with the iPhone in another room), a night for short-night
  wind-down, the two asleep fixes, the battery guard and the morning "no dark after the alarm", and a way to
  provoke "Recording stopped". Grouped so the sections fit the moments they need (2-min checks, one evening,
  one night).
- No app change: no IPA this round (build 105 is current).

### 49 · 2026-11-27 — round 40: saved state that outlived its moment (watch app change, install after recording)
- **Review (every state, across expiry and relaunch):** the persisted values added in rounds 22–38 were checked for
  what happens when their moment passes without the expected end.
  - F17's chosen nap length was cleared on Undo, on a new nap and when sleep was found — but not when a nap started
    by hand expired without sleep (90 min) or was stopped. It stayed saved and was applied to the **next planned
    nap**, silently changing its wake window.
  - F18's "already warned tonight" was in memory only; a relaunch inside the 5-min bedtime window warned twice.
  - Checked and fine: the away markers (cleared by the next home answer), the evening/day light memories (meant to
    last), the recent colours (unknown ids are skipped), the deferred step (now dropped by any newer change).
- **Changed:** `AlarmSettings.napWindow(chosen:manual:)` (tested) uses the chosen length only for the nap started
  by hand that is still armed; the length is also cleared when that nap's watch ends or the alarm is stopped.
  The battery guard's warned bedtime is saved.
- **Verified:** rule by unit tests (CI). No visual change; prototype not republished.

### 50 · 2026-11-27 — round 41: content instead of a spinner while checking (watch app change, install after recording)
- **Review:** round 24 kept the "Checking…" spinner because "with no state known there is no content to show". But
  the watch nearly always knows the lamp's last light (saved at every answer); only the first launch does not.
  A full-screen spinner for the 0.5–3 s of a check is the indeterminate indicator the HIG asks watch apps to avoid,
  and it makes the panel jump from spinner to slider.
- **Changed:** while checking, the panel shows the slider as the lamp last was — greyed (35 %), not touchable —
  with a "Checking…" pill in the middle; when the answer comes the live slider takes its place at the same spot.
  Only with nothing ever saved does the spinner remain. VoiceOver: "Lamp, checking, last 60 percent".
  Prototype: a "checking (last known)" connection state shows the same.
- **Verified:** CI build; prototype JS parses. **Needs the real watch:** that the change from greyed to live reads as
  "it's ready", not as a flicker.
- **Proposed:** F26 night cap.

### 51 · 2026-11-27 — round 42: F26 night cap built (unanswered → approved; watch app change, install after recording)
- **F26** (own commit): `LampRules.inNightCap`, `sliderTop(night:unlocked:current:)` and `nightCapped` (tested:
  inside/outside the night, locked/unlocked, never pulling a brighter light down, a switch-on with and without a
  remembered light, off untouched, daytime untouched). The slider's top at night is the cap — it stretches and
  clicks there exactly as at 100 %, so it reads as "the end", and the next drag from it goes on. The crown stops
  with a click; resting there ½ s and turning again goes on.
- **Review findings fixed before commit:** a capped 30 % switch-on at 3 am would have become the remembered
  evening light (F22), so the next evening the lamp would come on at 30 % — changes inside the night cap are not
  remembered. Turning the crown down from a light set brighter before the night must not jump it to 30 % — the top
  is never below where the lamp is.
- **Prototype:** "Night, cap at 30 %" switch with the same slider, crown and switch-on behaviour.
- **Verified:** rules by unit tests (CI); prototype JS parses. **Needs the real watch:** whether a second push feels
  natural or the cap feels like a wall at a moment you need light.

### 52 · 2026-11-27 — round 43: the night cap on every path, and visible (watch app change, install after recording)
- **Review of F26 against every input path:** slider ✓, crown ✓, tap and double tap (toggle) ✓, colour pick
  (keeps the brightness) ✓, automations (not capped, by design: they are not a fumble) ✓ — but VoiceOver's
  adjustable action went straight to `setLevel` and stepped past the cap. And the cap was only felt, never seen:
  a stop with no visual sign reads as a bug the first time.
- **Changed:** VoiceOver increments stop at 30 % at night and the next increment from there goes on (the same
  "second push"). At night, while the light is below 30 %, a faint hairline marks the stop on the slider (Swift and
  prototype); it disappears once the light is above it.
- **Verified:** uses the tested `sliderTop`; prototype JS parses. **Needs the real watch:** that the hairline is
  visible but quiet at night brightness.

### 53 · 2026-11-27 — round 44: the night cap explains itself (watch app change, install after recording)
- **Review:** the hairline shows where the night cap is, but at the moment the slider stops nothing says *why*, or
  that a second push exists — the one thing someone fumbling at 3 am needs to know.
- **Changed:** while the light is held at the cap (not yet pushed past), a small caption under the percentage says
  "Night · drag again for more" (dragging) or "Night · turn again for more" (crown); it fades with the percentage.
  Prototype in step. The on-watch checklist now covers builds 107–111 (night cap on every path, the checking state,
  the nap-length carry-over).
- **Verified:** CI build; prototype JS parses. **Needs the real watch:** caption legibility at night brightness.

### 54 · 2026-11-27 — round 45: the music bars ride out a dropped check (watch app change, install after recording)
- **Review:** the Now Playing sheet is the system's own (fine). The bars behind it are not: the watch asks the
  iPhone every 10 s, and one unreachable moment or one dropped reply set "playing" to false at once — the bars
  vanished mid-song and came back 10 s later. WatchConnectivity's reachability drops briefly all the time (the
  iPhone's link sleeps), so this flicker would be common exactly when music plays for a long time.
- **Changed:** a failed check keeps the last known "playing" for up to 30 s after the last real answer
  (`FaceRules.keepMusicBars`, tested: brief drop, long drop, not playing, never answered); a real "nothing
  playing" answer still hides the bars at once. Polling stays at 10 s (Tom asked for the bars to appear without
  "Check again"; a slower poll would delay that).
- **Prototype:** the music switch already shows the steady state; no change.
- **Verified:** rule by unit tests (CI). **Needs the real watch:** that the bars no longer blink during a long song.

### 55 · 2026-11-27 — round 46: the iPhone end, and the next idea (docs only, no new build)
- **Review:** the iPhone side of a lamp change (`WizClient`): set and status already go to all three bulbs at once
  (task group), each with 0.5 s timeouts and two retries, and a set that reaches no bulb falls back to a status — no
  latency to win there.
- **Research:** Apple Home's Adaptive Lighting shifts a bulb's colour temperature through the day — warmer in the
  morning, cooler at midday, warmer again in the evening — and choosing a colour or temperature by hand stops it.
  Sage already has the evening half (wind-down) and the morning half (sunrise); the day between is a fixed white.
- **Proposed:** F27 adaptive white (built next round if unanswered).
- No app change: build 112 is current.

### 56 · 2026-11-27 — round 47: F27 adaptive white built (unanswered → approved; watch app change, install after recording)
- **F27** (own commit): `LampRules.adaptiveKelvin` (the day's curve from today's sunrise/sunset of the rough
  position, 07:00/17:00 without one) and `adaptiveStep` (tested: curve points, ≤ 300 K steps, brightness kept, paused,
  colour, off, close enough, evening only-warmer). A 4-min check in `LampAutomation`; started with the app.
- **Review findings fixed before commit:** (1) after the wind-down had taken the lamp to 2200 K, the evening target
  of 2700 K would have pulled it cooler again — evening and night steps are only ever warmer. (2) A first version
  guessed "you chose a white" from the shape of the message; a switch-on carrying a remembered white (F22) would
  have counted. Now only choosing in the colour wheel pauses it — the one place a white or colour is chosen.
  (3) It stands aside for every other automation that owns the light at that moment (sunrise, its preview,
  wind-down, the 10 min after the alarm).
- **Prototype:** shows the adaptive white for the current time (07:00/17:00 day).
- **Verified:** rules by unit tests (CI). **Needs the real watch:** that 300 K steps every 4 min are not noticed.

### 57 · 2026-11-27 — round 48: adaptive white must not drown the night's evidence (watch app change, install after recording)
- **Review of F27 against everything else:** the contact log kept the last 40 messages, and its most important use
  is the morning check of last night's background steps (the open question of the whole lamp design). Adaptive
  white sends a step every 4 min while the white is moving — ~30 a day — all labelled "change (auto)": by evening
  the night entries would be gone, and the rest indistinguishable. Also, the white now changes by itself with
  nothing saying why.
- **Changed:** messages carry their source ("change (adaptive)"); the log keeps 120 and hides adaptive steps by
  default ("Hide adaptive white" switch at the top); the menu's "Now" says "Adaptive white · 3300 K" after a step
  (only when no other automation is speaking).
- **Checked, fine:** F27 with the switch-on memory (only your own changes are remembered), the night cap (no
  brightness change), arrival (sets a white the next step continues from), deferred retries (superseded by newer).
- **Verified:** CI build. **Needs the real watch:** nothing new beyond F27 itself.

### 58 · 2026-11-27 — round 49: steps that say "on" must know the lamp is on (watch app change, install after recording)
- **Review (user wins, stale state):** the wind-down and adaptive white decide from the watch's last known lamp
  state, which can be hours old while the app sat in the background. Their steps carry `"state": true`. Switch the
  lamp off at the wall or in the iPhone app in the evening and the next wind-down or adaptive step would switch it
  back on — automation overriding the plainest possible choice. (Arrival works on a fresh answer; the asleep
  fade only switches off; the sunrise is meant to switch on.)
- **Changed:** before such a step the state must be confirmed within 90 s (`LampRules.freshEnough`, tested); if it
  is older the watch asks once and waits up to 4 s, and skips the step when no answer comes. It asks only when the
  last known state says a step could happen (on, and white for adaptive), so a lamp that is off costs no messages.
  The on-watch checklist gains the wall-switch case, adaptive white and the log filter.
- **Verified:** rule by unit tests (CI). **Needs the real watch:** the wall-switch case in the checklist.

### 59 · 2026-11-27 — round 50: the same stale-state check for every automation (watch app change, install after recording)
- **Review:** round 49 covered the wind-down and adaptive white. Going through the others with the same question
  ("what if the watch's idea of the lamp is old?"):
  - **Sunrise:** "never dims a lamp" depends on the state — a stale "off" would send a 10 % candle step to a lamp you
    switched on bright this morning.
  - **Asleep fade:** its first step carries "on" — on a stale "on" it would switch a lamp that is already off back
    on, dim, as you fall asleep.
  - **Night-light timeout:** "only if it still shows the night light" — a stale state could switch off a light you
    changed in the iPhone app.
  - Fine as they are: arrival (decides on the answer that just came in), bedtime tap (asks first), alarm full light
    (meant to switch on), Try sunrise (you asked for it).
- **Changed:** all three decide on a state confirmed within 90 s (`freshState`, asked once if older). During a sunrise
  each step's reply keeps the state fresh, so it costs no extra messages there.
- **Verified:** CI build (the rule is round 49's tested `freshEnough`). **Needs real nights:** the contact log.

### 60 · 2026-11-27 — round 51: a dying battery must show in always-on (watch app change, install after recording)
- **Process:** a visual pass of the prototype in the browser pane was refused by the session's permission check;
  not worked around. The face was reviewed from the code instead, Swift against prototype: battery colours, music
  bars, runner trail and note geometry still match.
- **Review:** the battery bar is hidden in always-on and on the sleep face — reasonable at 70 %, wrong at 8 %: the
  moment the watch is about to stop recording (and the smart wake with it) is exactly the moment the face shows
  nothing, unless the wrist is raised.
- **Changed:** at 10 % and below and not charging (`FaceRenderer.criticalBattery`, tested) the red bar shows in
  always-on and on the sleep face too, at 60 % opacity. Prototype in step.
- **Verified:** rule by unit tests (CI); prototype JS parses. **Needs the real watch:** that always-on keeps it
  legible and it does not count as a bright element at night (it is small and only at ≤ 10 %).

### 61 · 2026-11-27 — round 52: the first real day (27 Nov) through the tools
- **Export (07:38–16:59):** iPhone GPS (median accuracy 16 m, 8 % of the time with a usable fix: mostly indoors),
  compass (4.8 lines/s: iOS halves device motion in the background), steps (6605), barometer and absolute
  altitude. The iPhone stopped at 12:10 — **its battery was empty** (Tom), not a tracking bug — and resumed at 16:58.
  The watch's own position tracking was off that day (the switch defaults to off).
- **Bug found (app):** the watch's barometer was timestamped ~26 years ahead, so the export's range "ended" in 2052
  and the watch barometer could not be used. The altimeter on watchOS 27 gives seconds since 2001, not since boot;
  adding the boot time put it in 2052. `RecordingFormat.unixTime` handles both (tested) and is now used for every
  Core Motion timestamp on both devices. Already recorded files keep the wrong times.
- **Bug found (tools):** the re-pocketing detection (any 45° turn within 10 s) cut the real day into dozens of
  periods of seconds; none could learn an offset, so the indoor path used none. A re-pocketing now needs the minute
  before and the minute after to each be steady (in a pocket, not a hand) and > 45° apart. The real day: one
  period, offset 96° learned from its GPS walks. Regression test 14/14 still passes.
- **The day, from the iPhone:** 9.4 h, ~4.7 km walked; floors: 07:40 up 3 by lift, 10:19 down 3 by lift, 10:39 up
  3 by lift, 10:50 down 1 by stairs, 11:06 up 1 by stairs; ~234 min on floor 3, 16 min on floor 2, 23 min on the
  ground floor. Apple's step counter counted no floors (it misses lifts, and the iPhone in a pocket often misses
  stairs) — the barometer's events are the ones to trust.

### 62 · 2026-11-27 — round 53: the real day's lessons into the tools (tools only, no new build)
- **Review:** two of the real day's problems would have been caught at a glance by the health check if it had known
  to look: the watch's Track position switch was off in every run while the iPhone's was on, and the watch
  barometer's times lay in 2052.
- **Changed:** `tools/check_export.py` now says when the watch's position tracking was off while the iPhone's was
  on, and when any position or pressure file has times in the future (with the build that fixed it). Checked on
  the 27 Nov export: both are reported.
- **Proposed:** F28 one switch for position (built next round if unanswered).
- No app change: build 120 is current.

### 63 · 2026-11-27 — round 54: F28 built (unanswered → approved; watch + iPhone change)
- **F28** (own commit): `PositionSync` (Shared): the message (on, time of the change), and `shouldFollow` — follow
  the other device only if its change is newer than this device's own last one (tested: newer, older, none, the
  message round trip). Only changes you make on a switch are sent; a change that arrives from the other device is
  applied without being sent back (no echo, no loop).
- **Review:** the application context keeps the iPhone's last change and is re-delivered with every other context
  update (sleep averages, alarm settings); the "newer than mine" rule makes re-delivery harmless. A change made
  while the other device is off arrives when it is back. Starting tracking on the iPhone from a watch message runs
  in the background; with location permission "While Using", iOS may not start it until the app is next opened
  (not shown on the card yet — open Sage on the iPhone once after switching on the watch if in doubt).
- **Verified:** rule by unit tests (CI). **Needs the real devices:** switch on the watch → iPhone card shows
  tracking within a minute; switch on the iPhone → the watch's menu shows it on.

### 64 · 2026-11-27 — round 55: the watch's switch must reach a closed iPhone app (iPhone change)
- **Review of F28:** the watch can now switch the iPhone's tracking, but with location permission "While Using"
  iOS does not let a closed or backgrounded Sage start location updates — the switch would silently do nothing
  until Sage is opened. The same permission also stops iOS from reopening Sage after it closed it (a significant
  move relaunches only apps with "Always").
- **Changed:** once "While Using" is granted and tracking runs, Sage asks iOS once to upgrade to "Always" (iOS
  shows that prompt only once, and only when the app is in use); the iPhone card says plainly when it is still
  "While Using" and what that means. New usage text for "Always" in the Info.plist.
- **Verified:** CI build. **Needs the real iPhone:** the upgrade prompt appears once; with Always, switching on at
  the watch starts the iPhone's tracking while Sage is closed.

### 65 · 2026-11-27 — round 56: a warning that cried wolf on the real day (tools only, no new build)
- **Review:** on 27 Nov the path's only warning said the step counter's floors (0 / 0) disagreed with the barometer
  (7 / 4) — but 9 of those 11 floors were lift rides, which Apple's step counter never counts. A warning that fires
  on a correct day teaches you to ignore warnings.
- **Changed:** the step counter is compared with the barometer's stairs only; the real day now has no warning (1 / 1
  by stairs against 0 / 0 is within the tolerance of one floor). Regression test 14/14.
- No app change: build 124 is current.

### 66 · 2026-11-27 — round 57: tracking must not drain the phone it runs on (watch + iPhone change)
- **Review after the real day:** the iPhone died at 12:10 while tracking, and the export cannot tell why or how fast:
  there is no battery log. The iPhone also asked for "best for navigation" accuracy all day, which Apple documents
  as meant for a device on power. Below 20 % the saver only coarsened GPS; nothing kept the phone itself alive.
- **Changed:** off the charger the iPhone uses plain "best" (navigation-grade only while charging). A last-reserve
  tier below 10 %: GPS ~100 m and the compass at 2 a second (watch: GPS ~100 m), back up with gaps (minimal → saver
  above 15 %, saver → best above 30 %; tested, the old saver test unchanged). A new `phonestatus` stream logs the
  iPhone's battery, charging and GPS mode once a minute; the health check lists it.
- **Verified:** rule by unit tests (CI). **Needs a real day:** the battery curve in the next export.

### 67 · 2026-11-27 — round 58: the checklist for the next recording day (docs only, no new build)
- The on-watch checklist gains a "Position day" section for builds 120–126: the one switch on both devices (F28),
  the "Always" prompt, the battery tiers and battery log, and an export check that the watch barometer's times
  are right. No app change: build 126 is current.
