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
