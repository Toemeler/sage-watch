import Foundation

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

    /// keep the controls (with "Reconnecting…") when the lamp answered recently, so one failed background check
    /// does not swap the panel away under your finger; show the "not reachable" view only after that
    static func showControls(home: Bool, sinceConfirmed: TimeInterval?) -> Bool {
        if home { return true }
        guard let s = sinceConfirmed else { return false }
        return s >= 0 && s < reconnectGrace
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
