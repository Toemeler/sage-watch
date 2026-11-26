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
