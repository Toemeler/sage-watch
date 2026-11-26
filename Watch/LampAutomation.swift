import Foundation

/// The lamp working with the sleep plan, driven from the watch (it stays awake through the night with the recorder;
/// the iPhone app could not run a long fade in the background).
///
/// - **Sunrise (F1):** when a smart-wake window opens, the lamp fades up from 10 % candle-warm toward a soft daylight,
///   easing in (slow at first, as dawn does), reaching ~80 % at the latest wake; when the alarm rings it goes to
///   100 % within a few seconds. Steps every 20 s, small enough not to be seen as steps.
/// - **Wind-down (F2):** before your *usual* bedtime (the average of your recorded nights, an hour ahead) and your
///   usual nap time (average of recorded naps, 20 min ahead), a lamp that is on dims and warms step by step to 10 %
///   at 2200 K. It never switches the lamp on. Any change you make by hand pauses it until that sleep.
///
/// Both are on by default and can be switched off in the long-press menu. Nothing here plays a haptic or shows an
/// error: at 6 am or at bedtime a missed step is simply retried at the next one.
@MainActor
final class LampAutomation: ObservableObject {
    static let shared = LampAutomation()

    @Published var sunriseOn = UserDefaults.standard.object(forKey: "lampSunrise") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sunriseOn, forKey: "lampSunrise") }
    }
    @Published var windDownOn = UserDefaults.standard.object(forKey: "lampWindDown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(windDownOn, forKey: "lampWindDown") }
    }
    @Published var offWhenAsleepOn = UserDefaults.standard.object(forKey: "lampOffAsleep") as? Bool ?? true {
        didSet { UserDefaults.standard.set(offWhenAsleepOn, forKey: "lampOffAsleep") }
    }
    /// when the alarm last rang with the sunrise on: full light is sent again when you raise your wrist
    private var rangAt: Date?
    /// what it is doing right now, for the menu
    @Published private(set) var activity = ""

    private var sunriseTask: Task<Void, Never>?
    private var windDownTask: Task<Void, Never>?
    private var windDownPausedFor: Date?          // the bedtime whose wind-down was paused by a manual change
    private var windingDown = false               // the wind-down is running now (not just scheduled for later)

    static let windDownMinutes = 60.0

    // MARK: sunrise

    /// a smart-wake window opened; `latest` is when the alarm rings at the latest
    func sunrise(until latest: Date) {
        guard sunriseOn, latest > Date() else { return }
        sunriseTask?.cancel()
        let start = Date(), span = latest.timeIntervalSince(start)
        activity = "Sunrise until \(latest.formatted(date: .omitted, time: .shortened))"
        sunriseTask = Task { @MainActor in
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / span)
                let e = t * t                                       // slow at first, like dawn
                LampModel.shared.set(["state": true, "dimming": Int(10 + 70 * e), "temp": Int(2200 + 2000 * e)], byUser: false)
                if t >= 1 { break }
                try? await Task.sleep(for: .seconds(20))
            }
            if !Task.isCancelled { activity = "" }
        }
    }

    /// the alarm rang: full light now (if the sunrise was running or the lamp is already on)
    func alarmRang() {
        let running = sunriseTask != nil && !(sunriseTask?.isCancelled ?? true)
        sunriseTask?.cancel(); sunriseTask = nil
        activity = ""
        guard sunriseOn, running || LampModel.shared.state.on else { return }
        rangAt = Date()
        LampModel.shared.set(["state": true, "dimming": 100, "temp": 4500], byUser: false)
    }

    /// the app came to the front (wrist raised): in the minutes after the alarm, make sure the light really is on,
    /// since the step sent while the app was in the background may not have reached the iPhone
    func appBecameActive() {
        LampModel.shared.retryDeferred()
        if let r = rangAt, Date().timeIntervalSince(r) < 10 * 60, !LampModel.shared.state.on || LampModel.shared.state.dimming < 100 {
            LampModel.shared.set(["state": true, "dimming": 100, "temp": 4500], byUser: false)
        }
        if let r = rangAt, Date().timeIntervalSince(r) >= 10 * 60 { rangAt = nil }
    }

    // MARK: asleep (F6)

    /// the watch found that you fell asleep (night or nap): a lamp that is on fades off, the wind-down stops
    func fellAsleep() {
        windDownTask?.cancel(); windDownTask = nil
        guard offWhenAsleepOn else { return }
        activity = "Off: you fell asleep"
        let lamp = LampModel.shared
        guard lamp.state.on else { return }
        // two steps rather than a cut, so a half-asleep glance never sees the room snap dark
        let from = lamp.state.dimming
        Task { @MainActor in
            lamp.set(["state": true, "dimming": max(10, from / 3)], byUser: false)
            try? await Task.sleep(for: .seconds(20))
            lamp.set(["state": false], byUser: false)
        }
    }

    /// a manual change stops a running sunrise (you took over)
    /// You changed the lamp yourself. Your setting wins: nothing automatic may undo it.
    /// - a running sunrise stops, and the "full light after the alarm" re-send is dropped
    /// - a running wind-down pauses until that sleep (one only scheduled for later is left alone)
    func userChanged() {
        rangAt = nil
        if sunriseTask != nil { sunriseTask?.cancel(); sunriseTask = nil; activity = "" }
        if windingDown, let task = windDownTask {
            windDownPausedFor = nextBedtime().at
            task.cancel(); windDownTask = nil; windingDown = false
            activity = "Wind-down paused: you set the lamp"
            scheduleWindDown()                      // arms the one after (the paused one is skipped)
        }
    }

    // MARK: wind-down

    /// When you usually go to sleep: the average onset of your recorded nights and naps (from the iPhone, once two
    /// of each are recorded), the plan's preset until then. The lamp dims toward these, not toward the presets.
    struct Bedtime: Equatable {
        let at: Date
        let nap: Bool
        let learned: Bool
        var lead: TimeInterval { nap ? 20 * 60 : LampAutomation.windDownMinutes * 60 }
    }

    func nextBedtime(after now: Date = .now) -> Bedtime {
        let cal = Calendar.current
        let t = Plan.typical
        let night = (t?.nightOnset).map { ($0, true) } ?? (Plan.night.onset, false)
        let nap = (t?.napOnset).map { ($0, true) } ?? (Plan.nap.onset, false)
        var all: [Bedtime] = []
        for off in -1...1 {
            let day = cal.date(byAdding: .day, value: off, to: cal.startOfDay(for: now))!
            all.append(Bedtime(at: day.addingTimeInterval(night.0 * 60), nap: false, learned: night.1))
            all.append(Bedtime(at: day.addingTimeInterval(nap.0 * 60), nap: true, learned: nap.1))
        }
        return all.filter { $0.at > now }.min { $0.at < $1.at }!
    }

    /// call when the app starts and whenever it becomes active; arms the next wind-down (night or nap)
    func scheduleWindDown(now: Date = .now) {
        guard windDownOn else { windDownTask?.cancel(); windDownTask = nil; windingDown = false; return }
        var bed = nextBedtime(after: now)
        if windDownPausedFor == bed.at { bed = nextBedtime(after: bed.at.addingTimeInterval(60)) }   // skip the paused one
        guard windDownTask == nil else { return }
        let begin = bed.at.addingTimeInterval(-bed.lead)
        windDownTask = Task { @MainActor in
            if begin > Date() { try? await Task.sleep(for: .seconds(begin.timeIntervalSinceNow)) }
            guard !Task.isCancelled else { return }
            windingDown = true
            defer { windingDown = false }
            let when = bed.at.formatted(date: .omitted, time: .shortened)
            activity = "Winding down to your \(bed.learned ? "usual " : "")\(bed.nap ? "nap" : "bedtime") \(when)"
            let lamp = LampModel.shared
            let fromDim = Double(max(lamp.state.dimming, 10)), fromK = Double(lamp.state.temp ?? 2700)
            let step: TimeInterval = bed.nap ? 60 : 180
            while !Task.isCancelled && Date() < bed.at {
                let t = min(1, max(0, 1 - bed.at.timeIntervalSinceNow / bed.lead))
                if lamp.state.on {          // never switch it on; only soften a lamp that is on
                    let dim = Int(fromDim + (10 - fromDim) * t), k = Int(fromK + (2200 - fromK) * t)
                    // only ever down: never brighter or cooler than the lamp is now (a colour is left as it is)
                    let target = max(10, min(dim, lamp.state.dimming))
                    var p: [String: Any] = ["state": true, "dimming": target]
                    if let cur = lamp.state.temp { p["temp"] = max(2200, min(k, cur)) }
                    if target < lamp.state.dimming || (p["temp"] as? Int).map({ $0 < (lamp.state.temp ?? 0) }) == true {
                        lamp.set(p, byUser: false)
                    }
                }
                try? await Task.sleep(for: .seconds(step))
            }
            guard !Task.isCancelled else { return }      // cancelled: whoever cancelled it owns what comes next
            windDownTask = nil
            activity = ""
            scheduleWindDown()
        }
    }

    /// the usual times changed (new averages from the iPhone): arm the wind-down again for them
    func rescheduleWindDown() {
        windDownTask?.cancel(); windDownTask = nil
        scheduleWindDown()
    }
}
