# On-watch test checklist

Everything below passed the cloud build and unit tests but has **not** been seen on a real watch. Each line is one
quick check; note ✓ / ✗ and anything odd. Long-press the face → **Lamp → Contact log** shows every lamp message.

## Face (2 min)
- [ ] Time centred, no date, thin battery bar; bar yellow ≤ 20 %, red ≤ 10 %, green while charging.
- [ ] Seconds runner smooth; no stutter when raising the wrist.
- [ ] Music playing on the iPhone → four bars above the battery within ~10 s (no "Check again" needed); tap them →
      pause / skip / back.
- [ ] VoiceOver on: the face reads the current time; "Now playing" is a button when music plays.

## Lamp panel (3 min, at home)
- [ ] Swipe up → panel slides up, fill rises into place.
- [ ] Tap anywhere: on/off. Slide: brightness from where it was; past the top/bottom it stretches and springs back.
- [ ] The percentage appears only while changing; split dark/white exactly at the fill edge.
- [ ] Crown: 1 % per click, click at 100 % and at off; below 10 % one more click down = off.
- [ ] Hold ~0.4 s → colour wheel blooms; pan does **not** pick; tap picks; edge bubbles easy to hit; crown zooms out.
- [ ] Leave it untouched 30 s → closes by itself (not while the colour wheel is open).
- [ ] iPhone in another room / Bluetooth off → change something → "Lamp didn't respond", slider snaps back.

## Face gestures (2 min)
- [ ] Crown **up** a few clicks → lamp panel. Crown **down** a long turn (12 clicks) → "Nap: watching for sleep ·
      Undo" (Record must be on); Undo cancels it.
- [ ] Double tap (pinch twice; watchOS 11 + a watch with double tap) → "Lamp on/off · Undo".
- [ ] During a sleep block, crown and double tap do nothing.

## Alarm
- [ ] Test alarm from the iPhone (Alarm tab) → while it taps: swipe up, crown and long-press do nothing;
      **double tap stops it**.

## Night (one night)
- [ ] Before bed with the lamp on: Lamp → Now shows "Winding down to your (usual) bedtime …"; lamp dims and warms.
      Change it by hand → "Wind-down paused"; it never gets brighter again.
- [ ] Fall asleep with the lamp on → it fades off in two steps (Off when asleep).
- [ ] On the charger after 21:00 → dim red bedside clock (if watchOS keeps Sage on screen there).
- [ ] Morning: lamp rises during the wake window, full light at the alarm.
- [ ] **Most important:** next morning open Lamp → Contact log. Are the night entries ("change (auto) ·
      background") ✓ or ✗? ✗ means the iPhone could not be reached from the background; the fix is the home bridge.
