# On-watch test checklist

Everything below passed the cloud build and unit tests but has **not** been seen on a real watch. Each line is one
quick check; note ✓ / ✗ and anything odd. Long-press the face → **Lamp → Contact log** shows every lamp message.
Up to date with build 126 (design log rounds 1–57).

## Face (3 min)
- [ ] Time centred, no date, thin battery bar; bar yellow ≤ 20 %, red ≤ 10 %, green while charging.
- [ ] Seconds runner smooth; no stutter when raising the wrist. At the minute the digits morph smoothly (they are
      now drawn only then, to save battery).
- [ ] Music playing on the iPhone → four bars above the battery within ~10 s (no "Check again" needed); tap them →
      pause / skip / back.
- [ ] VoiceOver on: the face reads e.g. "12:41, battery 78 percent, recording"; "Now playing" is a button when
      music plays.
- [ ] Battery: after a normal day, Settings → Battery → Sage's share is lower than before build 103.

## Notes on the face (2 min)
- [ ] Every note is one line, also on the 40 mm watch and with a larger text size; the button (Undo / Restart) is
      never cut.
- [ ] Lower the wrist while a note shows → it is not there in always-on.
- [ ] With a note with Undo up, double tap presses Undo (watchOS 11 + double tap).
- [ ] VoiceOver reads each note as it appears; the button says what it undoes ("Undo, Welcome home").

## Lamp panel (4 min, at home)
- [ ] Swipe up → panel slides up, fill rises into place.
- [ ] Tap anywhere: on/off. Slide: brightness from where it was; past the top/bottom it stretches and springs back.
- [ ] The percentage appears only while changing; split dark/white exactly at the fill edge.
- [ ] Crown slowly: 1 % per click; spin it: much faster (10 → 100 % in under a turn). Click at 100 % and at off;
      below 10 % one more click down = off.
- [ ] Hold ~0.4 s → colour wheel blooms; pan does **not** pick; tap picks; edge bubbles easy to hit.
- [ ] In the colour wheel: the corner button is a back arrow (back to brightness, not closing); the crown zooms
      and clicks at both ends; the last three colours carry a small white dot; it opens with them in reach.
- [ ] Switch the lamp off, then on: in the evening it comes back in your last evening light, in the day in your
      last daytime one ("Light by time of day").
- [ ] Leave it untouched 30 s → closes by itself; the "not reachable" screen too.
- [ ] Lower the wrist with the panel open → raising it again shows the face.
- [ ] iPhone in another room / Bluetooth off → change something → "Lamp didn't respond", slider snaps back.
- [ ] Opening the panel while it asks the lamp: the slider as it last was, greyed, "Checking…" on it — no spinner
      (except the very first time) — then it turns live in place.
- [ ] Short drop → "Reconnecting…" (antenna, no spinner) and it reconnects by itself within ~10 s of the iPhone
      being back.
- [ ] A notification arriving mid-drag never switches the lamp; the panel still closes after 30 s.

## Menu (1 min)
- [ ] Long-press the face → Lamp shows Now, Last contact, "Automations: n of 6 on", Try sunrise, Contact log.
- [ ] Automations page: seven switches (incl. Night cap), each with a line saying what it does.
- [ ] Try sunrise (60 s): dims to candle, rises to daylight, full light, then back to exactly how it was. Touch the
      lamp midway → it stops and keeps yours.

## Face gestures (2 min)
- [ ] Crown **up** a few clicks → lamp panel.
- [ ] Crown **down** a long turn (12 clicks) → "Nap · up to 100 min · Undo" (Record must be on). Pause, then turn:
      the length changes in 5-min steps with a click each (up longer, down shorter, 20–130). The menu shows
      "This nap: up to N min". Undo cancels it. A nap started by hand that never finds sleep does not change the
      length of the next planned nap.
- [ ] Double tap (pinch twice; watchOS 11 + a watch with double tap) → "Lamp on/off · Undo".
- [ ] During a sleep block, crown and double tap do nothing.

## Alarm
- [ ] Test alarm from the iPhone (Alarm tab) → while it taps: swipe up, crown and long-press do nothing;
      **double tap stops it**.

## Coming home (one evening)
- [ ] Leave home for over 20 min with the watch app opened at least twice while out; come home after dark with
      the lamp off → raise the wrist at home → lamp on in your evening light, "Welcome home · Undo".
- [ ] Undo switches it off; it does not come back on for 10 min.
- [ ] Sitting at home with the iPhone in another room for an hour must **never** trigger it.

## Night (one night)
- [ ] Before bed with the lamp on: Lamp → Now shows "Winding down to your (usual) bedtime …"; lamp dims and warms.
      Change it by hand → "Wind-down paused"; it never gets brighter again. After a short night (an hour less
      than usual) it starts 90 min before bed ("early (short night)").
- [ ] Fall asleep with the lamp on → it fades off in two steps. Touch the lamp between the steps → it stays on.
- [ ] Reading in bed, lamp changed after you lay down → it is not switched off.
- [ ] Night cap (between your usual bedtime and wake): a faint line marks 30 % on the slider; dragging stops there
      with a click and "Night · drag again for more"; a second drag goes higher. Crown stops at 30 %; rest ½ s and
      turn again to go on. Switching on at night comes on at most 30 %. Next evening the lamp still comes on in your
      evening light (not 30 %). VoiceOver: increments stop at 30 %, the next one goes on.
- [ ] Adaptive white (daytime, lamp on in white): the white drifts slowly (cooler toward midday, warmer toward
      evening), never noticed as a jump; "Now" shows "Adaptive white · … K". Pick a white in the wheel → it stays;
      switch off and on → it drifts again. In the evening it never gets cooler.
- [ ] Switch the lamp off with the wall switch or the iPhone app in the evening, then wait 10 min: the wind-down
      and adaptive white must **not** switch it back on.
- [ ] Contact log: adaptive steps hidden by default ("Hide adaptive white"); last night's entries are still there
      in the evening.
- [ ] On the charger after 21:00 → dim red bedside clock (if watchOS keeps Sage on screen there). Crown up → red
      night light; crown down → lamp off. Left alone, the night light goes off after 15 min.
- [ ] Wind-down off, lamp bright at your usual bedtime → two quiet clicks and "Bedtime · lamp is bright".
- [ ] At bedtime below 30 % and not on the charger, with Record on → one tap, "Charge for the alarm".
- [ ] Morning: lamp rises during the wake window, full light at the alarm; it does not go dark again when you
      raise the wrist afterwards.
- [ ] **Most important:** next morning open Lamp → Contact log. Are the night entries ("change (auto) ·
      background") ✓ or ✗? ✗ means the iPhone could not be reached from the background; the fix is the home bridge.

## Recording
- [ ] Settings → Privacy → Motion: switch Sage off for 11 min with Record on (daytime) → one tap, "Recording
      stopped · Restart" (8 s). Switch it back on, Restart → recording again. At night it waits until morning.

## Position day (one day, both devices)
- [ ] Switch Track position on at the watch → within a minute the iPhone's Position card shows it running (and the
      other way round). Switching off on one switches off the other.
- [ ] The iPhone asks once to allow location "Always"; allow it. If it stays "While Using", the card says what that
      means.
- [ ] Battery: the iPhone lasts the day (it died at 12:10 on 27 Nov). Below 20 % / 10 % the card says GPS saves power.
- [ ] Evening export → `tools/check_export.py`: watch and iPhone streams present, no "timestamps in the future"
      (the watch barometer is fixed from build 120), `phonestatus` (the iPhone's battery log) present.
