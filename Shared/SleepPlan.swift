import Foundation

// Port of plan.js: biphasic plan with smart wake.
//   Nap:   one cycle 17:00 -> 18:30, smart-wake window 18:15-18:30
//   Night: four cycles 00:30 -> 06:30, smart-wake window 06:00-06:30
// A plausible sleep architecture (deep early, REM late, cycles 84-98 min) stands in for real stages until HealthKit is wired.

enum Stage: String { case awake = "AWAKE", light = "LIGHT", deep = "DEEP", rem = "REM" }

struct StagePoint { let stage: Stage; let depth: Double }

struct SleepBlock {
    let onset: Double          // minutes after midnight (night block uses 24+ for after-midnight times)
    let end: Double
    let windowStart: Double
    let nCycles: Int
    let lens: [Double]
    let wake: Double
    var minutes: Double { wake - onset }

    init(onset: Double, end: Double, nCycles: Int, windowStart: Double, seed: Int64) {
        var s = seed
        func rnd() -> Double { s = (s &* 16807) % 2147483647; return Double(s) / 2147483647 }
        var l: [Double] = []
        for _ in 0..<nCycles { l.append(84 + (rnd() * 14).rounded()) }
        let total = l.reduce(0, +), scale = (end - onset) / total
        for k in 0..<nCycles { l[k] *= scale * (0.97 + rnd() * 0.03) }
        self.onset = onset; self.end = end; self.windowStart = windowStart; self.nCycles = nCycles; self.lens = l
        // smart wake: first minute in the window that is light sleep near the end of a cycle, else the alarm itself
        var w = end
        var t = windowStart
        while t < end {
            let st = SleepBlock.stage(at: t - onset, lens: l)
            if st.stage == .light && st.depth < 0.2 { w = t; break }
            t += 1
        }
        self.wake = w
    }

    static func cycleStage(_ u: Double, _ k: Int, _ n: Int) -> StagePoint {
        let late = n > 1 ? Double(k) / Double(n - 1) : 0
        let deep = 0.40 * (1 - late) + 0.04, rem = 0.12 + 0.2 * late
        let a = 0.14, b = a + deep, c = 1 - rem - 0.04
        if u < a { return StagePoint(stage: .light, depth: 0.25 + u / a * 0.2) }
        if u < b {
            let v = sin((u - a) / deep * .pi)
            return StagePoint(stage: v > 0.35 ? .deep : .light, depth: 0.45 + 0.55 * v * (1 - 0.6 * late))
        }
        if u < c { return StagePoint(stage: .light, depth: 0.32) }
        if u < 1 - 0.04 { return StagePoint(stage: .rem, depth: 0.2 + 0.06 * sin(u * 40)) }
        return StagePoint(stage: .light, depth: 0.14)
    }

    static func stage(at m: Double, lens: [Double]) -> StagePoint {
        if m < 0 { return StagePoint(stage: .awake, depth: -0.25) }
        var t = m
        for k in 0..<lens.count {
            if t < lens[k] { return cycleStage(t / lens[k], k, lens.count) }
            t -= lens[k]
        }
        return StagePoint(stage: .light, depth: 0.12)
    }

    func stageAt(_ m: Double) -> StagePoint { SleepBlock.stage(at: m, lens: lens) }

    /// stage samples every 4 minutes from onset to the smart wake (for hypnograms)
    var samples: [StagePoint] { stride(from: 0.0, to: minutes, by: 4).map { stageAt($0) } }
}

enum Plan {
    static let nap = SleepBlock(onset: 17 * 60, end: 18 * 60 + 30, nCycles: 1, windowStart: 18 * 60 + 15, seed: 11)
    static let night = SleepBlock(onset: 24 * 60 + 30, end: 30 * 60 + 30, nCycles: 4, windowStart: 30 * 60, seed: 29)

    static func fmt(_ m: Double) -> String {
        let v = ((Int(m.rounded()) % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", v / 60, v % 60)
    }
    static func dayClock(_ d: Date, _ cal: Calendar = .current) -> Double {
        let c = cal.dateComponents([.hour, .minute, .second], from: d)
        return Double(c.hour! * 60 + c.minute!) + Double(c.second!) / 60
    }
    /// times before 12:00 count as "after midnight" of the night block (24+)
    static func nightClock(_ d: Date, _ cal: Calendar = .current) -> Double { let m = dayClock(d, cal); return m < 720 ? m + 1440 : m }
    static func inNap(_ d: Date, _ cal: Calendar = .current) -> Bool { let m = dayClock(d, cal); return m >= nap.onset && m < nap.wake }
    static func afterNap(_ d: Date, _ cal: Calendar = .current) -> Bool { let m = dayClock(d, cal); return m >= nap.wake && m < nap.wake + 30 }
    static func inNight(_ d: Date, _ cal: Calendar = .current) -> Bool { let m = nightClock(d, cal); return m >= night.onset && m < night.wake }
    static func napLeftSeconds(_ d: Date, _ cal: Calendar = .current) -> Double { max(0, (nap.wake - dayClock(d, cal)) * 60) }
    static var totalSleep: Double { night.minutes + nap.minutes }
}

enum FaceMode: String, CaseIterable {
    case morning, lunch, afternoon, moving, pause, evening, sleeping, nap, afterNap, weekend

    /// the automatic schedule (port of modes.js autoMode, activity sensing not wired yet)
    static func auto(_ d: Date, _ cal: Calendar = .current) -> FaceMode {
        let wd = cal.component(.weekday, from: d)          // 1 = Sunday ... 7 = Saturday
        let weekend = wd == 1 || wd == 7
        let night = Plan.nightClock(d, cal), day = Plan.dayClock(d, cal), h = day / 60
        if Plan.inNight(d, cal) { return .sleeping }
        if night >= 1440 && night < Plan.night.onset { return .evening }            // 00:00-00:30 is still the wind-down
        if night >= Plan.night.wake && night < 1440 + 9.5 * 60 { return .morning }
        if Plan.inNap(d, cal) { return .nap }
        if Plan.afterNap(d, cal) { return .afterNap }
        if day >= Plan.nap.wake { return .evening }
        if weekend { return .weekend }
        if h >= 11.75 && h < 13.25 { return .lunch }
        return .afternoon
    }

    /// the line under the time
    func label(_ d: Date, _ cal: Calendar = .current) -> String {
        switch self {
        case .afternoon:
            let left = Int(Plan.nap.onset - Plan.dayClock(d, cal))
            let wd = cal.component(.weekday, from: d)
            if wd != 1 && wd != 7 && left > 0 && left <= 120 { return String(format: "NAP IN %dH %02dM", left / 60, left % 60) }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.timeZone = cal.timeZone; f.dateFormat = "MMMM"
            return f.string(from: d).uppercased()
        case .evening:
            let left = Int(Plan.night.onset - Plan.nightClock(d, cal))
            return left > 0 && left <= 180 ? String(format: "SLEEP IN %dH %02dM", left / 60, left % 60) : "GOOD EVENING"
        case .morning: return "NIGHT \(Self.hm(Plan.night.minutes)) · TOTAL \(Self.hm(Plan.totalSleep))"
        case .lunch: return "LUNCH BREAK"
        case .moving: return "ON THE MOVE"
        case .pause: return "TAKING A BREAK"
        case .sleeping: return ""
        case .nap: return "NAP"
        case .afterNap: return "CYCLE DONE · WOKE \(Plan.fmt(Plan.nap.wake))"
        case .weekend: return "SUNSET 16:48"
        }
    }
    static func hm(_ m: Double) -> String { let v = Int(m); return "\(v / 60)H \(String(format: "%02d", v % 60))M" }
}

// MARK: - calendar: concrete windows and events

extension Plan {
    enum Block: String { case nap, night }

    /// a concrete smart-wake window on the calendar
    struct WakeWindow: Equatable {
        let block: Block
        let start: Date        // window opens: the watch starts listening for light sleep
        let end: Date          // latest wake (the alarm)
        let predicted: Date    // the model's smart-wake minute
    }

    /// `minutes` after midnight of the day `dayOffset` days from `now`'s day (night minutes are 24+ of the evening's day)
    private static func date(_ now: Date, _ dayOffset: Int, _ minutes: Double, _ cal: Calendar) -> Date {
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))!
        return cal.date(byAdding: .second, value: Int((minutes * 60).rounded()), to: day)!
    }

    /// the next smart-wake window that has not ended yet (it may already be open)
    static func nextWakeWindow(after now: Date, _ cal: Calendar = .current) -> WakeWindow {
        var all: [WakeWindow] = []
        for off in -1...1 {
            all.append(WakeWindow(block: .nap, start: date(now, off, nap.windowStart, cal), end: date(now, off, nap.end, cal), predicted: date(now, off, nap.wake, cal)))
            all.append(WakeWindow(block: .night, start: date(now, off, night.windowStart, cal), end: date(now, off, night.end, cal), predicted: date(now, off, night.wake, cal)))
        }
        return all.filter { $0.end > now }.min { $0.start < $1.start }!
    }

    /// the next time a sleep block begins
    static func nextSleep(after now: Date, _ cal: Calendar = .current) -> (block: Block, at: Date) {
        var all: [(Block, Date)] = []
        for off in -1...1 {
            all.append((.nap, date(now, off, nap.onset, cal)))
            all.append((.night, date(now, off, night.onset, cal)))
        }
        let next = all.filter { $0.1 > now }.min { $0.1 < $1.1 }!
        return (next.0, next.1)
    }
}
