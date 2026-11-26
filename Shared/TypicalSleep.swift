import Foundation

/// What your recorded sleep actually looks like: the average start and end of your recent naps and nights.
///
/// Used for the lamp: the wind-down dims toward your *usual* bedtime and nap time (the average of the last 14
/// recorded, once there are two), not toward the plan's presets. The plan, the face and the smart alarm keep their
/// own times; in particular the alarm's wake window must not follow averaged wakes, since you are always woken inside
/// it and the average would pull it earlier night after night.
struct TypicalSleep: Codable, Equatable {
    var napOnset: Double?          // minutes after midnight
    var napWake: Double?
    var napCount = 0
    var nightOnset: Double?        // night clock: times before 12:00 count as 24+ (00:40 = 1480)
    var nightWake: Double?
    var nightCount = 0

    static let minimumSamples = 2
    static let window = 14

    /// `naps` and `nights` as (onset, wake) in unix seconds, newest first or in any order
    static func from(naps: [(Double, Double)], nights: [(Double, Double)], calendar cal: Calendar = .current) -> TypicalSleep {
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        func clock(_ t: Double, night: Bool) -> Double {
            let d = Date(timeIntervalSince1970: t)
            return night ? Plan.nightClock(d, cal) : Plan.dayClock(d, cal)
        }
        let n = Array(naps.sorted { $0.0 > $1.0 }.prefix(window))
        let g = Array(nights.sorted { $0.0 > $1.0 }.prefix(window))
        var t = TypicalSleep()
        t.napCount = n.count
        t.nightCount = g.count
        if n.count >= minimumSamples {
            t.napOnset = mean(n.map { clock($0.0, night: false) })
            t.napWake = mean(n.map { clock($0.1, night: false) })
        }
        if g.count >= minimumSamples {
            t.nightOnset = mean(g.map { clock($0.0, night: true) })
            // a wake is after midnight by definition; nightClock puts it at 24+ as well
            t.nightWake = mean(g.map { clock($0.1, night: true) })
        }
        return t
    }

    var dictionary: [String: Any] {
        var d: [String: Any] = ["napCount": napCount, "nightCount": nightCount]
        if let napOnset { d["napOnset"] = napOnset }
        if let napWake { d["napWake"] = napWake }
        if let nightOnset { d["nightOnset"] = nightOnset }
        if let nightWake { d["nightWake"] = nightWake }
        return d
    }

    init() {}

    init?(dictionary d: [String: Any]?) {
        guard let d else { return nil }
        napOnset = d["napOnset"] as? Double
        napWake = d["napWake"] as? Double
        napCount = d["napCount"] as? Int ?? 0
        nightOnset = d["nightOnset"] as? Double
        nightWake = d["nightWake"] as? Double
        nightCount = d["nightCount"] as? Int ?? 0
    }
}

extension Plan {
    private static let typicalKey = "typicalSleep"
    private static var typicalCache: TypicalSleep? = {
        guard let data = UserDefaults.standard.data(forKey: typicalKey) else { return nil }
        return try? JSONDecoder().decode(TypicalSleep.self, from: data)
    }()

    /// the learned averages (nil until something is recorded); saved, so it is there on the next launch
    static var typical: TypicalSleep? {
        get { typicalCache }
        set {
            typicalCache = newValue
            if let newValue, let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: typicalKey) }
            napPlanCache = nil
            nightPlanCache = nil
        }
    }

    private static var napPlanCache: SleepBlock?
    private static var nightPlanCache: SleepBlock?

    /// your nap as recorded (average of the last naps), or the preset until two are recorded
    static var napPlan: SleepBlock {
        if let c = napPlanCache { return c }
        var b = nap
        if let t = typical, let on = t.napOnset, let wk = t.napWake, wk > on + 10 {
            b = SleepBlock(onset: on, end: wk, nCycles: 1, windowStart: wk, seed: 11)
        }
        napPlanCache = b
        return b
    }

    /// your night as recorded (average of the last nights), or the preset until two are recorded
    static var nightPlan: SleepBlock {
        if let c = nightPlanCache { return c }
        var b = night
        if let t = typical, let on = t.nightOnset, let wk = t.nightWake, wk > on + 60 {
            b = SleepBlock(onset: on, end: wk, nCycles: max(1, Int(((wk - on) / 90).rounded())), windowStart: wk, seed: 29)
        }
        nightPlanCache = b
        return b
    }

    /// whether the plan shows recorded averages, for the Plan tab's footnote
    static var napIsLearned: Bool { (typical?.napOnset) != nil }
    static var nightIsLearned: Bool { (typical?.nightOnset) != nil }
}
