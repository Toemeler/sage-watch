import Foundation
import WatchKit

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
    @Published var bedtimeTapOn = UserDefaults.standard.object(forKey: "lampBedtimeTap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bedtimeTapOn, forKey: "lampBedtimeTap") }
    }
    @Published var arrivalOn = UserDefaults.standard.object(forKey: "lampArrival") as? Bool ?? true {
        didSet { UserDefaults.standard.set(arrivalOn, forKey: "lampArrival") }
    }
    /// F22: switching on brings back your last light for this time of day (evening or daytime)
    @Published var switchOnMemoryOn = UserDefaults.standard.object(forKey: "lampSwitchOnMemory") as? Bool ?? true {
        didSet { UserDefaults.standard.set(switchOnMemoryOn, forKey: "lampSwitchOnMemory") }
    }
    /// F26: at night the slider and the crown stop at 30 %
    @Published var nightCapOn = UserDefaults.standard.object(forKey: "lampNightCap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(nightCapOn, forKey: "lampNightCap") }
    }
    /// F27: while the lamp is on in white, its white follows the day
    @Published var adaptiveOn = UserDefaults.standard.object(forKey: "lampAdaptive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(adaptiveOn, forKey: "lampAdaptive") }
    }
    /// F27: you chose a white or a colour yourself: adaptive white rests until the lamp is next switched off
    var adaptivePaused: Bool {
        get { UserDefaults.standard.bool(forKey: "lampAdaptivePaused") }
        set { UserDefaults.standard.set(newValue, forKey: "lampAdaptivePaused") }
    }
    private var adaptiveTask: Task<Void, Never>?

    static let automationCount = 8
    /// how many of the automations are on (the menu's summary)
    var enabledCount: Int {
        [sunriseOn, windDownOn, offWhenAsleepOn, bedtimeTapOn, arrivalOn, switchOnMemoryOn, nightCapOn, adaptiveOn]
            .filter { $0 }.count
    }
    /// when the bedtime tap last fired (the face shows a note for it)
    @Published private(set) var bedtimeTappedAt: Date?
    /// when the arrival light (F16) last switched the lamp on (the face shows a note with Undo)
    @Published private(set) var arrivedAt: Date?
    private var arrivalClear: Task<Void, Never>?
    private var bedtimeTask: Task<Void, Never>?
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
                // eased like dawn; never dims a lamp that is already brighter (LampRules, tested)
                if let p = LampRules.sunrise(t: t, current: LampModel.shared.state) { LampModel.shared.set(p, byUser: false) }
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

    private var asleepTask: Task<Void, Never>?

    /// the watch found that you fell asleep at `onset` (night or nap): a lamp that is on fades off, the wind-down
    /// stops. Not if you changed the lamp yourself after `onset` (LampRules.offWhenAsleep, tested).
    func fellAsleep(onset: Date = .now) {
        windDownTask?.cancel(); windDownTask = nil
        guard offWhenAsleepOn else { return }
        let lamp = LampModel.shared
        guard lamp.state.on, LampRules.offWhenAsleep(onset: onset, lastUserChange: lamp.userChangedAt) else { return }
        activity = "Off: you fell asleep"
        // two steps rather than a cut, so a half-asleep glance never sees the room snap dark. The second step is
        // cancelled by any change of yours in between (userChanged): you are awake, your light stays.
        let from = lamp.state.dimming
        asleepTask?.cancel()
        asleepTask = Task { @MainActor in
            lamp.set(["state": true, "dimming": max(10, from / 3)], byUser: false)
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            lamp.set(["state": false], byUser: false)
            asleepTask = nil
        }
    }

    /// a manual change stops a running sunrise (you took over)
    /// You changed the lamp yourself. Your setting wins: nothing automatic may undo it.
    /// - a running sunrise stops, and the "full light after the alarm" re-send is dropped
    /// - a running wind-down pauses until that sleep (one only scheduled for later is left alone)
    func userChanged() {
        rangAt = nil
        if previewTask != nil { previewTask?.cancel(); previewTask = nil; previewing = false; activity = "" }   // no restore: yours wins
        if asleepTask != nil { asleepTask?.cancel(); asleepTask = nil; activity = "" }      // awake after all: no second step
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
        /// F20: the night's wind-down starts this much earlier after a short night
        var earlier: TimeInterval = 0
        var lead: TimeInterval { (nap ? 20 * 60 : LampAutomation.windDownMinutes * 60) + earlier }
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
        var next = all.filter { $0.at > now }.min { $0.at < $1.at }!
        if !next.nap, let t = Plan.typical {
            let base = LampAutomation.windDownMinutes * 60
            next.earlier = LampRules.windDownLead(base: base, nap: false, lastNightMinutes: t.lastNightMinutes,
                                                  usualMinutes: t.nightMinutes,
                                                  sinceLastNight: t.lastNightEnd.map { now.timeIntervalSince1970 - $0 }) - base
        }
        return next
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
            activity = "Winding down\(bed.earlier > 0 ? " early (short night)" : "") to your \(bed.learned ? "usual " : "")\(bed.nap ? "nap" : "bedtime") \(when)"
            let lamp = LampModel.shared
            let startState = lamp.state
            let step: TimeInterval = bed.nap ? 60 : 180
            while !Task.isCancelled && Date() < bed.at {
                let t = min(1, max(0, 1 - bed.at.timeIntervalSinceNow / bed.lead))
                // only ever lower and warmer, never on, colour left alone (LampRules, tested)
                if let p = LampRules.windDown(t: t, start: startState, current: lamp.state) { lamp.set(p, byUser: false) }
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
        bedtimeTask?.cancel(); bedtimeTask = nil
        scheduleBedtimeTap()
    }

    // MARK: arrival light (F16)

    /// The lamp answered again after you were away (the iPhone found no bulb over `awaySpan`, last `sinceAway` ago). After dark, with the
    /// lamp off and nothing against it (LampRules.arrivalLight, tested), it comes on warm. Seen when the watch next
    /// asks the lamp: raising the wrist at the door, not the moment the iPhone joins the Wi-Fi.
    func arrived(awaySpan: TimeInterval, sinceAway: TimeInterval) {
        guard arrivalOn else { return }
        let lamp = LampModel.shared, now = Date()
        var bed = nextBedtime(after: now)
        while bed.nap { bed = nextBedtime(after: bed.at.addingTimeInterval(60)) }
        guard let p = LampRules.arrivalLight(awaySpan: awaySpan, sinceAway: sinceAway, dark: Sun.darkHere(at: now),
                                             sleeping: FaceMode.auto(now) == .sleeping, lampOn: lamp.state.on,
                                             panelOpen: lamp.panelOpen,
                                             sinceUserOff: lamp.userOffAt.map { now.timeIntervalSince($0) },
                                             inWindDown: bed.at.timeIntervalSince(now) <= bed.lead,
                                             evening: switchOnMemoryOn ? UserDefaults.standard.dictionary(forKey: LampModel.memoryKey(dark: true)) : nil)
        else { return }
        lamp.set(p, byUser: false)
        arrivedAt = now
        activity = "Welcome home: lamp on"
        // the menu's "Now" says what is happening, not what happened an evening ago
        arrivalClear?.cancel()
        arrivalClear = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10 * 60))
            if !Task.isCancelled, activity == "Welcome home: lamp on" { activity = "" }
        }
    }

    // MARK: adaptive white (F27)

    /// starts the adaptive white's check every 4 min (idempotent; the recorder keeps the app running)
    func startAdaptive() {
        guard adaptiveTask == nil else { return }
        adaptiveTask = Task { @MainActor in
            while !Task.isCancelled {
                adaptiveTick(now: Date())
                try? await Task.sleep(for: .seconds(240))
            }
        }
    }

    /// one step toward the day's white, unless something else is in charge of the light right now: the sunrise,
    /// its preview, the wind-down, the minutes after the alarm, or a white / colour you chose (LampRules, tested)
    private func adaptiveTick(now: Date) {
        guard adaptiveOn, sunriseTask == nil, !previewing, !windingDown, rangAt == nil else { return }
        let lamp = LampModel.shared
        guard lamp.home else { return }
        let cal = Calendar.current
        let minutes = Double(cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now))
        let d = UserDefaults.standard
        var rise = 7 * 60.0, set = 17 * 60.0
        if let lat = d.object(forKey: "approxLat") as? Double, let lon = d.object(forKey: "approxLon") as? Double,
           let t = Sun.times(on: now, lat: lat, lon: lon) {
            rise = Double(cal.component(.hour, from: t.rise) * 60 + cal.component(.minute, from: t.rise))
            set = Double(cal.component(.hour, from: t.set) * 60 + cal.component(.minute, from: t.set))
        }
        let target = LampRules.adaptiveKelvin(minutes: minutes, sunrise: rise, sunset: set)
        let evening = minutes >= set || minutes < rise
        if let p = LampRules.adaptiveStep(current: lamp.state, target: target, paused: adaptivePaused, onlyWarmer: evening) {
            lamp.set(p, byUser: false, source: "adaptive")
            if activity.isEmpty || activity.hasPrefix("Adaptive white") {
                activity = "Adaptive white · \(p["temp"] as? Int ?? target) K"      // why the white just changed
            }
        }
    }

    /// F27: the lamp went off (by anyone): the next time it is on, the adaptive white may take it again
    func lampSwitchedOff() { adaptivePaused = false }

    // MARK: try the sunrise (F14)

    @Published private(set) var previewing = false
    private var previewTask: Task<Void, Never>?

    /// The whole wake-up light in 60 s: from 10 % candle along the same curve as the real sunrise (LampRules.sunrise)
    /// to 80 % daylight, then full light as the alarm would, held 5 s, then the lamp goes back to exactly how it was.
    /// Touching the lamp at any point stops it and keeps what you set (no restore).
    func trySunrise() {
        guard !previewing else { return }
        sunriseTask?.cancel(); sunriseTask = nil
        let lamp = LampModel.shared
        let before = lamp.state
        previewing = true
        activity = "Trying the sunrise (60 s)"
        previewTask = Task { @MainActor in
            defer { previewing = false; previewTask = nil }
            // start from the dawn end even if the lamp is on bright, so there is something to see
            lamp.set(["state": true, "dimming": 10, "temp": 2200], byUser: false)
            let start = Date(), span: TimeInterval = 60
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / span)
                if let p = LampRules.sunrise(t: t, current: lamp.state) { lamp.set(p, byUser: false) }
                if t >= 1 { break }
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            lamp.set(["state": true, "dimming": 100, "temp": 4500], byUser: false)      // the alarm's full light
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            lamp.set(LampRules.restore(before), byUser: false)
            activity = ""
        }
    }

    // MARK: night light timeout

    private var nightLightTask: Task<Void, Never>?

    /// the night light was switched on from the bedside clock: off again after 15 min if it is still the night
    /// light (LampRules.nightLightExpired, tested), so a 3 am trip does not leave the room red until morning
    func nightLightStarted() {
        nightLightTask?.cancel()
        let setAt = Date()
        nightLightTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(LampRules.nightLightMinutes))
            guard !Task.isCancelled else { return }
            let lamp = LampModel.shared
            if LampRules.nightLightExpired(current: lamp.state, setAt: setAt, now: Date()) {
                lamp.set(["state": false], byUser: false)
                activity = "Night light off after 15 min"
            }
        }
    }

    // MARK: bedtime tap (F13)

    /// At your usual bedtime (the night's, not the nap's): two quiet clicks on the wrist when the lamp is still
    /// bright and wind-down is off (LampRules.bedtimeTap, tested). The lamp is asked fresh first, so a stale state
    /// never taps. Clicks, not the notification haptic, which can play a tone.
    func scheduleBedtimeTap() {
        guard bedtimeTapOn, bedtimeTask == nil else { return }
        var bed = nextBedtime(after: .now)
        while bed.nap { bed = nextBedtime(after: bed.at.addingTimeInterval(60)) }
        let at = bed.at
        bedtimeTask = Task { @MainActor in
            if at > Date() { try? await Task.sleep(for: .seconds(at.timeIntervalSinceNow)) }
            guard !Task.isCancelled else { return }
            let lamp = LampModel.shared
            lamp.refresh(force: true)
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if bedtimeTapOn, lamp.home, LampRules.bedtimeTap(lampOn: lamp.state.on, dimming: lamp.state.dimming, windDownOn: windDownOn) {
                WKInterfaceDevice.current().play(.click)
                try? await Task.sleep(for: .milliseconds(350))
                WKInterfaceDevice.current().play(.click)
                bedtimeTappedAt = Date()
                activity = "Bedtime: the lamp is still bright"
            }
            bedtimeTask = nil
            scheduleBedtimeTap()                          // the next night
        }
    }
}
