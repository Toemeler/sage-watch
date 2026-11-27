import Foundation
import CoreGraphics

/// Watch ↔ iPhone messages for the WiZ lamps. watchOS cannot send UDP, so the watch asks the iPhone, which talks
/// to the bulbs on the home network (local WiZ API, UDP 38899, see C:\Users\Tom\wiz-local).
enum LampLink {
    static let commandKey = "lamp"          // "status" | "set"
    static let paramsKey = "params"         // setPilot params for "set"
    static let status = "status", set = "set"
    /// headphones and playback on the iPhone: reply {"bluetooth": Bool, "device": String, "playing": Bool}
    static let audio = "audio"

    /// what the iPhone replies to either command
    struct State: Equatable {
        var home = false          // at least one bulb answered on the local network
        var on = false
        var dimming = 100         // 10...100
        var temp: Int? = 2700     // white temperature in K, nil while a colour is set
        var rgb: (Int, Int, Int)? = nil
        var count = 0             // bulbs that answered

        static func == (a: State, b: State) -> Bool {
            a.home == b.home && a.on == b.on && a.dimming == b.dimming && a.temp == b.temp && a.count == b.count
                && a.rgb?.0 == b.rgb?.0 && a.rgb?.1 == b.rgb?.1 && a.rgb?.2 == b.rgb?.2
        }

        var dictionary: [String: Any] {
            var d: [String: Any] = ["home": home, "on": on, "dimming": dimming, "count": count]
            if let temp { d["temp"] = temp }
            if let rgb { d["r"] = rgb.0; d["g"] = rgb.1; d["b"] = rgb.2 }
            return d
        }

        init() {}

        init(_ d: [String: Any]) {
            home = d["home"] as? Bool ?? false
            on = d["on"] as? Bool ?? false
            dimming = d["dimming"] as? Int ?? 100
            temp = d["temp"] as? Int
            count = d["count"] as? Int ?? 0
            if let r = d["r"] as? Int, let g = d["g"] as? Int, let b = d["b"] as? Int { rgb = (r, g, b) }
        }

        /// a bulb's getPilot result
        init(pilot p: [String: Any]) {
            home = true; count = 1
            on = p["state"] as? Bool ?? false
            dimming = p["dimming"] as? Int ?? 100
            if let t = p["temp"] as? Int, t > 0 { temp = t; rgb = nil }
            else if let r = p["r"] as? Int, let g = p["g"] as? Int, let b = p["b"] as? Int { rgb = (r, g, b); temp = nil }
        }
    }

    /// white presets (K) and colours offered on the watch, Control Center style
    static let temps = [2200, 2700, 3500, 4500, 6500]
    static let colours: [(Int, Int, Int)] = [(255, 60, 0), (255, 140, 0), (255, 0, 60), (190, 0, 255), (0, 80, 255), (0, 200, 120)]
}

/// The rules for automatic lamp steps, in one place so they can be tested. The principle: automation may only ever
/// move the lamp in its own direction (sunrise brighter, wind-down dimmer and warmer), and never undo what you set.
enum LampRules {
    /// how long after the lamp last answered the panel keeps its controls through a failed check
    static let reconnectGrace: TimeInterval = 120

    /// setPilot params that put the lamp back exactly as it was (after a preview): off stays off, a colour comes
    /// back as that colour, a white as that white
    static func restore(_ s: LampLink.State) -> [String: Any] {
        guard s.on else { return ["state": false] }
        var p: [String: Any] = ["state": true, "dimming": s.dimming]
        if let c = s.rgb { p["r"] = c.0; p["g"] = c.1; p["b"] = c.2 } else { p["temp"] = s.temp ?? 2700 }
        return p
    }

    /// F22: what to remember of a light you set yourself (nil when it is off, or the bedside night light, which
    /// must never come back as the evening's light)
    static func memory(of s: LampLink.State) -> [String: Any]? {
        guard s.on else { return nil }
        if let c = s.rgb, c.0 == 255, c.1 == 28, c.2 == 0, s.dimming <= 10 { return nil }
        var p = restore(s)
        p["state"] = nil
        return p
    }

    /// F22: switching on from off brings back the light remembered for this time of day; nothing remembered:
    /// just on (the bulb keeps its own last light)
    static func switchOn(memory: [String: Any]?) -> [String: Any] {
        var p: [String: Any] = [:]
        for k in ["dimming", "temp", "r", "g", "b"] { if let v = memory?[k] { p[k] = v } }
        p["state"] = true
        return p
    }

    /// a night light switches itself off after this long (you got up and went back to bed)
    static let nightLightMinutes: TimeInterval = 15 * 60

    /// whether the night light set at `setAt` should go off now: only if the lamp still shows it (dim red at 10 %)
    /// and it has been on for nightLightMinutes; anything you changed since is yours and stays
    static func nightLightExpired(current: LampLink.State, setAt: Date, now: Date) -> Bool {
        guard current.on, current.dimming <= 10, let c = current.rgb, c.0 > 200, c.1 < 60, c.2 < 30 else { return false }
        return now.timeIntervalSince(setAt) >= nightLightMinutes
    }

    /// F13: at your usual bedtime, tap the wrist only when the lamp is still bright and nothing else is taking care
    /// of it (wind-down off). If wind-down is on (running or paused by your own change), you chose; no nagging.
    static func bedtimeTap(lampOn: Bool, dimming: Int, windDownOn: Bool) -> Bool {
        lampOn && dimming > 30 && !windDownOn
    }

    /// keep the controls (with "Reconnecting…") when the lamp answered recently, so one failed background check
    /// does not swap the panel away under your finger; show the "not reachable" view only after that
    static func showControls(home: Bool, sinceConfirmed: TimeInterval?) -> Bool {
        if home { return true }
        guard let s = sinceConfirmed else { return false }
        return s >= 0 && s < reconnectGrace
    }

    /// the panel closes after this long unused, as Control Center does
    static let idleCloseAfter: TimeInterval = 30
    /// while "Reconnecting…" shows, the watch tries again this often
    static let reconnectEvery: TimeInterval = 8

    /// F6: switch the lamp off for a sleep that began at `onset`? Not when you changed the lamp yourself after that
    /// moment: you were awake then, whatever the motion said (reading in bed, still), and your light stays.
    static func offWhenAsleep(onset: Date, lastUserChange: Date?) -> Bool {
        guard let u = lastUserChange else { return true }
        return u < onset
    }

    /// brightness per crown detent, by how fast the crown turns: 1 % when turned slowly (precise), rising to 4 % when
    /// spun (10 → 100 % in under a turn instead of three), as the system matches scrolling to the crown's speed.
    /// `dt`: seconds since the previous detent.
    static func crownStep(secondsSinceLast dt: TimeInterval) -> Double {
        if dt >= 0.12 { return 1 }
        if dt <= 0.03 { return 4 }
        return 1 + 3 * (0.12 - dt) / 0.09
    }

    /// F26: at night the slider and the crown stop here
    static let nightCapLevel = 0.30

    /// F26: is it night for the cap? Between your usual bedtime and wake, in night-clock minutes (after midnight
    /// counts as 24+), the same clock the plan uses
    static func inNightCap(nightClock m: Double, onset: Double, wake: Double) -> Bool {
        m >= onset && m < wake
    }

    /// F26: the top of the slider / crown: 30 % at night until unlocked (a second push from the cap, or a fresh
    /// turn after resting there), else 100 %. Never below where the lamp already is: a light set brighter before
    /// is never pulled down by the cap.
    static func sliderTop(night: Bool, unlocked: Bool, current: Double = 0) -> Double {
        guard night && !unlocked else { return 1 }
        return max(nightCapLevel, current)
    }

    /// F26: switching on at night brings back at most 30 %
    static func nightCapped(_ params: [String: Any], night: Bool, currentDimming: Int) -> [String: Any] {
        guard night, params["state"] as? Bool == true else { return params }
        var p = params
        let d = (p["dimming"] as? Int) ?? currentDimming
        if d > Int(nightCapLevel * 100) { p["dimming"] = Int(nightCapLevel * 100) }
        return p
    }

    /// F25: lowering the wrist (the app leaves the front) closes the panel, so the next raise shows the face, as
    /// Control Center does; never while a finger is still on the slider
    static func closeOnWristDown(active: Bool, touching: Bool) -> Bool {
        !active && !touching
    }

    /// close the panel when unused for `idleCloseAfter`; never under a finger or while the colours are open
    static func idleClose(idle: TimeInterval, touching: Bool, colours: Bool) -> Bool {
        !touching && !colours && idle > idleCloseAfter
    }

    /// try to reach the lamp again while reconnecting, but never start a check while one is still out (a slow
    /// WatchConnectivity reply would otherwise pile up checks and keep the radio busy)
    static func retryReconnect(sinceLastTry: TimeInterval, busy: Bool) -> Bool {
        !busy && sinceLastTry >= reconnectEvery
    }

    /// F16: "away" needs the iPhone to answer "no bulb replied" at least twice, this far apart (one flaky answer
    /// at home is not leaving) ...
    static let arrivalAway: TimeInterval = 20 * 60
    /// ... and the lamp to answer again within this time of the last "away" answer (a home reply hours later says
    /// only that the watch had not asked, not that you just walked in)
    static let arrivalFresh: TimeInterval = 30 * 60
    /// F16: a lamp you switched off this recently is not switched on again by an arrival
    static let arrivalOffGrace: TimeInterval = 10 * 60

    /// F16, coming home after dark: the lamp comes on warm, dimmer inside the wind-down before bedtime (the level
    /// wind-down would be heading to; an hour, or longer after a short night, F20). `awaySpan`: from the first to the last "away" answer; `sinceAway`: from the
    /// last "away" answer to now. Nil whenever it must not: away not proven, not fresh, not dark, a sleep block, the
    /// lamp already on, the lamp panel open (you are about to set it yourself; a tap there would toggle it straight
    /// back off), or you switched it off in the last 10 min. Automation never switches on over your own choice.
    /// F23: outside the wind-down it comes on in `evening`, your remembered evening light (F22), when there is one.
    static func arrivalLight(awaySpan: TimeInterval, sinceAway: TimeInterval, dark: Bool, sleeping: Bool, lampOn: Bool,
                             panelOpen: Bool, sinceUserOff: TimeInterval?, inWindDown: Bool,
                             evening: [String: Any]? = nil) -> [String: Any]? {
        guard awaySpan >= arrivalAway, sinceAway >= 0, sinceAway <= arrivalFresh else { return nil }
        guard dark, !sleeping, !lampOn, !panelOpen else { return nil }
        if let s = sinceUserOff, s >= 0, s < arrivalOffGrace { return nil }
        if inWindDown { return ["state": true, "dimming": 25, "temp": 2200] }
        // F23: your own evening light when there is one (F22), else a warm 60 %
        if let e = evening, e["dimming"] != nil { return switchOn(memory: e) }
        return ["state": true, "dimming": 60, "temp": 2700]
    }

    /// F20: how much earlier the night's wind-down starts after a short night
    static let shortNightExtraLead: TimeInterval = 30 * 60

    /// F20: the wind-down's lead before bedtime. After a short night (the last recorded one over an hour shorter
    /// than usual, and it was last night: ended under 20 h ago) the night's wind-down starts 30 min earlier. Naps
    /// keep their lead. Only the lamp follows this; the plan and the alarm do not.
    static func windDownLead(base: TimeInterval, nap: Bool, lastNightMinutes: Double?, usualMinutes: Double?,
                             sinceLastNight: TimeInterval?) -> TimeInterval {
        guard !nap, let l = lastNightMinutes, let u = usualMinutes, let s = sinceLastNight,
              s >= 0, s < 20 * 3600, u - l > 60 else { return base }
        return base + shortNightExtraLead
    }

    /// F21: how many recent colours the wheel marks
    static let recentLimit = 3

    /// F21: the recent colours (cell ids, newest first) after choosing `id`: it moves to the front, no doubles
    static func recents(_ list: [Int], adding id: Int) -> [Int] {
        Array(([id] + list.filter { $0 != id }).prefix(recentLimit))
    }

    /// F21: where the colour wheel opens. Centred on the colour that is set (as the app grid opens on the last app),
    /// unless the set colour and the recent ones all fit around their middle without leaving the full-size centre
    /// zone (`half`: its half extents) — then on that middle, so the recents are in reach too. Nothing set and
    /// nothing recent: the middle of the wheel.
    static func openCentre(current: CGPoint?, recents: [CGPoint], half: CGSize) -> CGPoint {
        let all = (current.map { [$0] } ?? []) + recents
        guard !all.isEmpty else { return .zero }
        let mid = CGPoint(x: all.map(\.x).reduce(0, +) / CGFloat(all.count), y: all.map(\.y).reduce(0, +) / CGFloat(all.count))
        let fits = all.allSatisfy { abs($0.x - mid.x) <= half.width && abs($0.y - mid.y) <= half.height }
        return fits ? mid : (current ?? recents[0])
    }

    /// one sunrise step at progress `t` (0...1 through the wake window): eased like dawn, 10 → 80 % and
    /// 2200 → 4200 K. Nil when the lamp is already on and at least that bright (you or an earlier step set it):
    /// a sunrise never dims a lamp.
    static func sunrise(t: Double, current: LampLink.State) -> [String: Any]? {
        let p = min(1, max(0, t)), e = p * p
        let dim = Int((10 + 70 * e).rounded()), temp = Int((2200 + 2000 * e).rounded())
        if current.on && current.dimming >= dim { return nil }
        return ["state": true, "dimming": dim, "temp": temp]
    }

    /// one wind-down step at progress `t` from `start` (the lamp when the wind-down began) toward 10 % at 2200 K.
    /// Never switches the lamp on, never brighter or cooler than it is now, leaves a colour as it is.
    /// Nil when there is nothing to lower.
    static func windDown(t: Double, start: LampLink.State, current: LampLink.State) -> [String: Any]? {
        guard current.on else { return nil }
        let p = min(1, max(0, t))
        let fromDim = Double(max(start.dimming, 10)), fromK = Double(start.temp ?? current.temp ?? 2700)
        let dim = max(10, min(Int((fromDim + (10 - fromDim) * p).rounded()), current.dimming))
        var out: [String: Any] = ["state": true, "dimming": dim]
        var lowersTemp = false
        if let cur = current.temp {
            let k = max(2200, min(Int((fromK + (2200 - fromK) * p).rounded()), cur))
            out["temp"] = k
            lowersTemp = k < cur
        }
        return dim < current.dimming || lowersTemp ? out : nil
    }
}
