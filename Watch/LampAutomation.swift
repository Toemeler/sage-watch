import Foundation

/// The lamp working with the sleep plan, driven from the watch (it stays awake through the night with the recorder;
/// the iPhone app could not run a long fade in the background).
///
/// - **Sunrise (F1):** when a smart-wake window opens, the lamp fades up from 10 % candle-warm toward a soft daylight,
///   easing in (slow at first, as dawn does), reaching ~80 % at the latest wake; when the alarm rings it goes to
///   100 % within a few seconds. Steps every 20 s, small enough not to be seen as steps.
/// - **Wind-down (F2):** in the hour before the night's bedtime, if the lamp is on, it dims and warms step by step
///   (every 3 min) to 10 % at 2200 K. It never switches the lamp on. Any change you make by hand pauses it for the
///   evening.
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
    /// what it is doing right now, for the menu
    @Published private(set) var activity = ""

    private var sunriseTask: Task<Void, Never>?
    private var windDownTask: Task<Void, Never>?
    private var windDownPausedFor: Date?          // the bedtime whose wind-down was paused by a manual change

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
        LampModel.shared.set(["state": true, "dimming": 100, "temp": 4500], byUser: false)
    }

    /// a manual change stops a running sunrise (you took over)
    func userChanged() {
        if sunriseTask != nil { sunriseTask?.cancel(); sunriseTask = nil; activity = "" }
        if windDownTask != nil { windDownPausedFor = nextBedtime(); windDownTask?.cancel(); windDownTask = nil; activity = "Wind-down paused tonight" }
    }

    // MARK: wind-down

    /// call when the app starts and whenever it becomes active; arms the next wind-down
    func scheduleWindDown(now: Date = .now) {
        guard windDownOn else { windDownTask?.cancel(); windDownTask = nil; return }
        let bed = nextBedtime(now: now)
        guard windDownPausedFor != bed, windDownTask == nil else { return }
        let begin = bed.addingTimeInterval(-Self.windDownMinutes * 60)
        windDownTask = Task { @MainActor in
            if begin > Date() { try? await Task.sleep(for: .seconds(begin.timeIntervalSinceNow)) }
            guard !Task.isCancelled else { return }
            activity = "Winding down until \(bed.formatted(date: .omitted, time: .shortened))"
            let lamp = LampModel.shared
            let fromDim = Double(max(lamp.state.dimming, 10)), fromK = Double(lamp.state.temp ?? 2700)
            while !Task.isCancelled && Date() < bed {
                let t = 1 - bed.timeIntervalSinceNow / (Self.windDownMinutes * 60)
                if lamp.state.on {          // never switch it on; only soften a lamp that is on
                    let dim = Int(fromDim + (10 - fromDim) * t), k = Int(fromK + (2200 - fromK) * t)
                    lamp.set(["state": true, "dimming": max(10, dim), "temp": max(2200, k)], byUser: false)
                }
                try? await Task.sleep(for: .seconds(180))
            }
            windDownTask = nil
            activity = ""
            scheduleWindDown()
        }
    }

    private func nextBedtime(now: Date = .now) -> Date {
        var next = Plan.nextSleep(after: now.addingTimeInterval(-Self.windDownMinutes * 60))
        // the night only (the nap has its own short routine without a wind-down)
        var probe = now.addingTimeInterval(-Self.windDownMinutes * 60)
        while next.block != .night { probe = next.at.addingTimeInterval(60); next = Plan.nextSleep(after: probe) }
        return next.at
    }
}
