import Foundation

/// The five vibration strengths, softest first. The watch maps each to a system haptic (`SmartAlarm.haptic`).
enum AlarmLevel: Int, CaseIterable {
    case click, tap, knock, alert, buzz

    var name: String {
        switch self {
        case .click: return "Click"
        case .tap: return "Tap"
        case .knock: return "Knock"
        case .alert: return "Alert"
        case .buzz: return "Buzz"
        }
    }

    static func name(_ level: Int) -> String {
        (AlarmLevel(rawValue: min(max(level, 0), AlarmLevel.allCases.count - 1)) ?? .click).name
    }
}

/// How the silent alarm vibrates. Set on the iPhone (Data › Vibration alarm), kept on both devices and sent to the
/// watch, where the real smart alarm and the test both play it.
///
/// A pulse plays every `gap` seconds and has `taps` taps. The pulses start at `startLevel` and climb in whole steps
/// to `peakLevel` over `rampMinutes`; a test squeezes that climb into the first 60 % of its length.
struct AlarmSettings: Equatable {
    var startLevel = 0
    var peakLevel = 3
    var rampMinutes = 2.0
    var gap = 2.5
    var taps = 1
    var testSeconds = 20.0
    var testDelayMinutes = 0.0
    /// the real alarm stops by itself after this long (you can always stop it earlier: Stop, a hard shake, the iPhone)
    var ringMinutes = 3.0
    /// nap: the earliest and latest wake, in minutes after the moment you fell asleep
    var napEarliest = 70.0
    var napLatest = 100.0

    static let levels = 0...(AlarmLevel.allCases.count - 1)
    static let rampRange = 0.0...10.0
    static let gapRange = 1.0...6.0
    static let tapsRange = 1...4
    static let testRange = 10.0...60.0
    static let delayRange = 0.0...30.0
    static let ringRange = 1.0...10.0
    static let napEarliestRange = 50.0...90.0
    static let napLatestRange = 60.0...130.0
    /// the nap's wake window is at least this wide
    static let napMinimumWindow = 10.0

    /// seconds between the taps of one pulse (closer taps tend to merge into one)
    static let tapSpacing = 0.6

    /// every value inside its range, and the peak never below the start
    func clamped() -> AlarmSettings {
        var s = self
        s.startLevel = Self.clamp(startLevel, Self.levels)
        s.peakLevel = max(Self.clamp(peakLevel, Self.levels), s.startLevel)
        s.rampMinutes = Self.clamp(rampMinutes.isFinite ? rampMinutes : 2, Self.rampRange)
        s.gap = Self.clamp(gap.isFinite ? gap : 2.5, Self.gapRange)
        s.taps = Self.clamp(taps, Self.tapsRange)
        s.testSeconds = Self.clamp(testSeconds.isFinite ? testSeconds : 20, Self.testRange)
        s.testDelayMinutes = Self.clamp(testDelayMinutes.isFinite ? testDelayMinutes : 0, Self.delayRange)
        s.ringMinutes = Self.clamp(ringMinutes.isFinite ? ringMinutes : 3, Self.ringRange)
        s.napEarliest = Self.clamp(napEarliest.isFinite ? napEarliest : 70, Self.napEarliestRange)
        s.napLatest = max(Self.clamp(napLatest.isFinite ? napLatest : 100, Self.napLatestRange), s.napEarliest + Self.napMinimumWindow)
        return s
    }

    /// strength (0…4) of a pulse that starts `t` seconds into the alarm, climbing evenly to the peak at `ramp` seconds
    func level(at t: Double, ramp: Double) -> Int {
        let s = clamped()
        let steps = s.peakLevel - s.startLevel
        guard steps > 0, ramp > 0 else { return s.peakLevel }
        let fraction = min(max(t / ramp, 0), 1)
        return s.startLevel + min(Int((fraction * Double(steps)).rounded(.down)), steps)
    }

    /// seconds after a pulse starts at which its taps play
    var tapOffsets: [Double] {
        (0..<clamped().taps).map { Double($0) * Self.tapSpacing }
    }

    /// the gap actually used: a burst always finishes, with a short pause, before the next pulse
    var effectiveGap: Double {
        let s = clamped()
        return max(s.gap, Double(s.taps - 1) * Self.tapSpacing + 0.8)
    }

    var rampSeconds: Double { clamped().rampMinutes * 60 }
    var ringSeconds: Double { clamped().ringMinutes * 60 }
    var testRamp: Double { clamped().testSeconds * 0.6 }

    /// (seconds from the start, level) of every pulse in the first `length` seconds
    func pulses(length: Double, ramp: Double) -> [(time: Double, level: Int)] {
        let gap = effectiveGap
        var out: [(time: Double, level: Int)] = []
        var t = 0.0
        while t < length - 1e-9 {
            out.append((time: t, level: level(at: t, ramp: ramp)))
            t += gap
        }
        return out
    }

    // MARK: storage and transport (property-list values, so WatchConnectivity can carry them)

    var dictionary: [String: Any] {
        let s = clamped()
        return ["start": s.startLevel, "peak": s.peakLevel, "ramp": s.rampMinutes, "gap": s.gap,
                "taps": s.taps, "test": s.testSeconds, "delay": s.testDelayMinutes,
                "ring": s.ringMinutes, "napEarliest": s.napEarliest, "napLatest": s.napLatest]
    }

    init() {}

    /// missing or unreadable values fall back to the defaults
    init(dictionary d: [String: Any]?) {
        let d = d ?? [:]
        func number(_ k: String) -> NSNumber? { d[k] as? NSNumber }
        var s = AlarmSettings()
        if let v = number("start") { s.startLevel = v.intValue }
        if let v = number("peak") { s.peakLevel = v.intValue }
        if let v = number("ramp") { s.rampMinutes = v.doubleValue }
        if let v = number("gap") { s.gap = v.doubleValue }
        if let v = number("taps") { s.taps = v.intValue }
        if let v = number("test") { s.testSeconds = v.doubleValue }
        if let v = number("delay") { s.testDelayMinutes = v.doubleValue }
        if let v = number("ring") { s.ringMinutes = v.doubleValue }
        if let v = number("napEarliest") { s.napEarliest = v.doubleValue }
        if let v = number("napLatest") { s.napLatest = v.doubleValue }
        self = s.clamped()
    }

    static let defaultsKey = "alarmSettings"

    static func load(_ defaults: UserDefaults = .standard) -> AlarmSettings {
        AlarmSettings(dictionary: defaults.dictionary(forKey: defaultsKey))
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(dictionary, forKey: Self.defaultsKey)
    }

    private static func clamp<T: Comparable>(_ v: T, _ r: ClosedRange<T>) -> T { min(max(v, r.lowerBound), r.upperBound) }
}

/// iPhone ↔ watch messages for the vibration alarm.
enum AlarmLink {
    static let commandKey = "alarm"            // iPhone → watch: test, preview or stop
    static let test = "test"                   // play the pattern (after the delay in the settings)
    static let preview = "preview"             // one pulse at `levelKey`
    static let stop = "stop"                   // stop the ringing alarm or a test, or cancel a test that is waiting
    static let napNow = "nap"                  // watch for the moment you fall asleep now, wake one cycle later
    static let levelKey = "level"
    static let settingsKey = "alarmSettings"   // settings dictionary: in a test message and in the application context
    static let okKey = "ok"                    // watch → iPhone in the reply
    static let textKey = "text"
    static let ringingKey = "ringing"          // watch → iPhone in the reply: is the real alarm ringing?
}
