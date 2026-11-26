import Foundation

// Live detection on the watch: the moment you fall asleep, when a sleep cycle has ended, and a deliberate shake.
// OnsetDetector and WakeRule mirror the classes of the same names in tools/night_reference.py; the tests replay a
// real night through both.

/// One second of wrist motion as the recorder summarises it.
struct MotionSecond: Equatable {
    var t: Double
    var sd: Double
    var gx: Double
    var gy: Double
    var gz: Double
}

/// Finds the moment you fall asleep, as it happens.
///
/// Every 30 s epoch is "moving" when it has 2+ seconds of movement or the wrist turned more than 30° against a
/// minute earlier. An epoch is quiet when fewer than a quarter of the epochs within ±5 minutes of it are moving, so
/// the verdict on an epoch comes 5 minutes late. Ten quiet minutes in a row, with a heart rate that is not above
/// the half hour before, make the first of them the moment of falling asleep: reported 15 minutes after it,
/// dated back to it. On the night of 26 Nov this gave 01:10:30; Apple Health said 01:11.
struct OnsetDetector {
    static let window = 20          // epochs looked over
    static let confirm = 20         // quiet epochs in a row

    private struct Epoch { let start: Double; let valid: Bool; let moving: Bool; let gravity: (Double, Double, Double)? }

    private var epoch: Double?
    private var nsec = 0, movs = 0
    private var g = (0.0, 0.0, 0.0)
    private var hist: [Epoch] = []
    private var runStart: Double?
    private var runLength = 0
    private var heart: [(Double, Double)] = []
    private(set) var onset: Double?

    init() {}

    mutating func addHeart(t: Double, bpm: Double) {
        heart.append((t, bpm))
        let cut = t - 3600
        if let i = heart.firstIndex(where: { $0.0 >= cut }), i > 0 { heart.removeFirst(i) }
    }

    /// feed seconds in time order; returns the onset once found
    @discardableResult
    mutating func add(_ s: MotionSecond) -> Double? {
        let e = (s.t / NightAnalysis.Params.epoch).rounded(.down) * NightAnalysis.Params.epoch
        if epoch == nil { epoch = e }
        while let current = epoch, e > current {
            close()
            epoch = current + NightAnalysis.Params.epoch
        }
        nsec += 1
        if s.sd > NightAnalysis.Params.moveSD { movs += 1 }
        g.0 += s.gx; g.1 += s.gy; g.2 += s.gz
        return onset
    }

    private mutating func close() {
        var gravity: (Double, Double, Double)? = nil
        if nsec > 0 {
            let norm = (g.0 * g.0 + g.1 * g.1 + g.2 * g.2).squareRoot()
            if norm > 0 { gravity = (g.0 / norm, g.1 / norm, g.2 / norm) }
        }
        var posture = false
        if hist.count >= 2, let a = gravity, let b = hist[hist.count - 2].gravity {
            let dot = max(-1, min(1, a.0 * b.0 + a.1 * b.1 + a.2 * b.2))
            posture = acos(dot) * 180 / .pi > NightAnalysis.Params.postureDegrees
        }
        hist.append(Epoch(start: epoch ?? 0, valid: nsec >= 15, moving: movs >= NightAnalysis.Params.movingSeconds || posture, gravity: gravity))
        if hist.count > 60 { hist.removeFirst(hist.count - 60) }
        nsec = 0; movs = 0; g = (0, 0, 0)
        guard onset == nil, hist.count >= Self.window + 1 else { return }
        let w = hist.suffix(Self.window + 1)
        let centre = w[w.startIndex + Self.window / 2]
        let valid = w.filter(\.valid)
        let movingCount = valid.filter(\.moving).count
        let quiet = centre.valid && valid.count >= 10 && Double(movingCount) / Double(valid.count) < NightAnalysis.Params.quietFraction
        guard quiet else { runStart = nil; runLength = 0; return }
        if runStart == nil { runStart = centre.start }
        runLength += 1
        if runLength >= Self.confirm && heartSettled() { onset = runStart }
    }

    private func heartSettled() -> Bool {
        guard let start = runStart else { return true }
        let before = heart.filter { $0.0 >= start - 1800 && $0.0 < start }.map(\.1)
        let during = heart.filter { $0.0 >= start }.map(\.1)
        if before.count < 10 || during.count < 10 { return true }
        return Stats.median(during) <= Stats.median(before) + 1
    }
}

/// When a sleep cycle has ended: inside [opens, closes) the first stirring (3+ seconds of movement within a minute)
/// or a heart rate 8 bpm above its sleep baseline; at `closes` regardless.
struct WakeRule {
    enum Reason: String { case stirring, heart, latest }
    static let stirSeconds = 3
    static let heartRise = 8.0

    let onset: Double
    let opens: Double
    let closes: Double
    private var moving: [Double] = []
    private var heart: [(Double, Double)] = []

    init(onset: Double, opens: Double, closes: Double) {
        self.onset = onset; self.opens = opens; self.closes = closes
    }

    /// heart samples from before `onset` (for the record; the baseline starts 10 minutes after onset)
    mutating func remember(t: Double, bpm: Double) { heart.append((t, bpm)) }

    mutating func second(_ s: MotionSecond) -> Reason? {
        if s.sd > NightAnalysis.Params.moveSD { moving.append(s.t) }
        if let i = moving.firstIndex(where: { $0 > s.t - 60 }) { if i > 0 { moving.removeFirst(i) } } else { moving.removeAll() }
        if s.t >= closes { return .latest }
        if s.t >= opens && moving.count >= Self.stirSeconds { return .stirring }
        return nil
    }

    mutating func beat(t: Double, bpm: Double) -> Reason? {
        heart.append((t, bpm))
        if heart.count > 12_000 { heart.removeFirst(heart.count - 12_000) }
        if t >= closes { return .latest }
        if t < opens { return nil }
        let base = heart.filter { $0.0 >= onset + 600 && $0.0 < t - 300 }.map(\.1)
        let recent = heart.filter { $0.0 >= t - 120 && $0.0 <= t }.map(\.1)
        if base.count >= 30 && recent.count >= 5 && Stats.median(recent) >= Stats.median(base) + Self.heartRise { return .heart }
        return nil
    }
}

/// A deliberate shake of the wrist: 4 sharp peaks above 2.5 g within 2.5 s.
///
/// Tuned on your own data: over the whole night of 26 Nov your strongest movement made 2 such peaks; fighting the
/// alarm that morning made 5. Feed |a| in g at 25 Hz or faster.
struct ShakeDetector {
    static let threshold = 2.5
    static let peaks = 4
    static let window = 2.5
    static let minGap = 0.15

    private var above = false
    private var spikes: [Double] = []

    init() {}

    mutating func reset() { above = false; spikes.removeAll() }

    /// returns true once, when the shake is complete
    mutating func add(t: Double, magnitude m: Double) -> Bool {
        let isAbove = m >= Self.threshold
        defer { above = isAbove }
        guard isAbove && !above else { return false }
        if let last = spikes.last, t - last < Self.minGap { return false }
        spikes.append(t)
        spikes.removeAll { $0 < t - Self.window }
        if spikes.count >= Self.peaks {
            spikes.removeAll()
            return true
        }
        return false
    }
}
