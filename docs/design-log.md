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
