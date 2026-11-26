import Foundation

// Sleep analysis from the recorder's data: sleep window, breathing, estimated stages and cycles.
//
// This is a step-by-step port of tools/night_reference.py; the unit tests run both on a real night and compare.
// Change the two together. The stage labels are estimates from wrist data (stillness, heart rate and breathing
// regularity), not a sleep lab; the sleep window and the breathing rate are the solid parts.

/// one line per second of wrist motion (motion1s.csv)
struct SecondSeries {
    var t: [Double] = []
    var sd: [Double] = []
    var gx: [Double] = []
    var gy: [Double] = []
    var gz: [Double] = []
    var count: Int { t.count }
}

/// heart rate samples (hr.csv: unix_start, bpm)
struct HeartSeries {
    var t: [Double] = []
    var bpm: [Double] = []
    var count: Int { t.count }
}

/// raw motion on a regular 10 Hz grid: sample i is the mean of the raw samples in [start + i/10, start + (i+1)/10);
/// gaps of up to 4 samples are interpolated, longer gaps are NaN
struct Grid10 {
    var start: Double
    var x: [Double]
    var y: [Double]
    var z: [Double]
    var count: Int { x.count }

    /// mirrors resample10() in the reference
    init(t: [Double], x rx: [Double], y ry: [Double], z rz: [Double]) {
        guard let t0 = t.first, let tl = t.last else { start = 0; x = []; y = []; z = []; return }
        let g0 = (t0 * 10).rounded(.down) / 10
        let n = Int(((tl - g0) * 10).rounded(.down)) + 1
        var sx = [Double](repeating: 0, count: n), sy = sx, sz = sx
        var c = [Double](repeating: 0, count: n)
        for i in t.indices {
            var k = Int(((t[i] - g0) * 10 + 1e-9).rounded(.down))
            k = min(max(k, 0), n - 1)
            sx[k] += rx[i]; sy[k] += ry[i]; sz[k] += rz[i]; c[k] += 1
        }
        self = Grid10.finish(start: g0, sx: sx, sy: sy, sz: sz, c: c)
    }

    /// means per bin, then gaps of up to 4 bins interpolated (as resample10 in the reference)
    static func finish(start: Double, sx: [Double], sy: [Double], sz: [Double], c: [Double]) -> Grid10 {
        let n = c.count
        var ox = [Double](repeating: .nan, count: n), oy = ox, oz = ox
        for k in 0..<n where c[k] > 0 {
            ox[k] = sx[k] / c[k]; oy[k] = sy[k] / c[k]; oz[k] = sz[k] / c[k]
        }
        var i = 0
        while i < n {
            if c[i] > 0 { i += 1; continue }
            var j = i
            while j < n && c[j] == 0 { j += 1 }
            if i > 0 && j < n && j - i <= 4 {
                for k in i..<j {
                    let f = Double(k - (i - 1)) / Double(j - (i - 1))
                    ox[k] = ox[i - 1] + (ox[j] - ox[i - 1]) * f
                    oy[k] = oy[i - 1] + (oy[j] - oy[i - 1]) * f
                    oz[k] = oz[i - 1] + (oz[j] - oz[i - 1]) * f
                }
            }
            i = j
        }
        return Grid10(start: start, x: ox, y: oy, z: oz)
    }

    init(start: Double, x: [Double], y: [Double], z: [Double]) {
        self.start = start; self.x = x; self.y = y; self.z = z
    }
}

/// Builds a Grid10 over a fixed range from raw samples handed in piece by piece (a night of 50 Hz motion never has
/// to sit in memory at once). Bin edges fall on tenths of a second, as in Grid10(t:x:y:z:), so both agree.
struct Grid10Builder {
    let start: Double
    private var sx: [Double], sy: [Double], sz: [Double], c: [Double]

    init(from lo: Double, to hi: Double) {
        start = (lo * 10).rounded(.down) / 10
        let n = max(0, Int(((hi - start) * 10).rounded(.up)))
        sx = [Double](repeating: 0, count: n); sy = sx; sz = sx; c = sx
    }

    var isEmpty: Bool { !c.contains { $0 > 0 } }

    mutating func add(t: [Double], x: [Double], y: [Double], z: [Double]) {
        let n = c.count
        for i in t.indices {
            let k = Int(((t[i] - start) * 10 + 1e-9).rounded(.down))
            guard k >= 0 && k < n else { continue }
            sx[k] += x[i]; sy[k] += y[i]; sz[k] += z[i]; c[k] += 1
        }
    }

    func finish() -> Grid10 { Grid10.finish(start: start, sx: sx, sy: sy, sz: sz, c: c) }
}

enum SleepStage: Int, Codable, CaseIterable {
    case awake = 0, rem = 1, light = 2, deep = 3

    var name: String {
        switch self {
        case .awake: return "Awake"
        case .rem: return "REM"
        case .light: return "Light"
        case .deep: return "Deep"
        }
    }
}

struct NightAnalysis: Codable {
    struct Cycle: Codable, Equatable {
        var start: Double
        var end: Double
        /// true for a cycle that ended at a boundary, or a last part that ran a full cycle's length
        var complete: Bool
        /// minutes per stage, indexed by SleepStage.rawValue
        var stages: [Double]
        var minutes: Double { (end - start) / 60 }
    }

    struct Summary: Codable, Equatable {
        var minutes: Double
        var stages: [Double]
        var hrMean: Double?
        var hrMin: Double?
        /// lowest 5-minute median heart rate and when it ended
        var hrLow5: Double?
        var hrLow5At: Double?
        var breaths: Double?
        /// separate bursts of movement (moving seconds more than 30 s apart start a new burst)
        var bursts: Int
        var asleepMinutes: Double { minutes - stages[SleepStage.awake.rawValue] }
    }

    var onset: Double
    var wake: Double
    /// start of epoch 0; epochs are 30 s
    var epochStart: Double
    var stage: [SleepStage]
    var depth: [Double]
    var heart: [Double]
    var breaths: [Double]
    var movingSeconds: [Int]
    var cycles: [Cycle]
    var summary: Summary
    var epochCount: Int { stage.count }
    func time(ofEpoch k: Int) -> Double { epochStart + Double(k) * Params.epoch }
    /// full cycles only
    var completeCycles: [Cycle] { cycles.filter(\.complete) }
}

// MARK: - parameters (one place, so the next weeks of data can tune them)

extension NightAnalysis {
    enum Params {
        static let epoch: Double = 30
        // movement
        static let moveSD = 0.02
        static let movingSeconds = 2
        static let postureDegrees = 30.0
        static let awakeSeconds = 5
        // breathing
        static let breathN = 600
        static let breathStill = 0.02
        static let breathBins: [Int] = (1..<300).filter { Double($0) / 60 >= 0.12 && Double($0) / 60 <= 0.6 }
        static let breathProminence = 6.0
        // sleep window
        static let quietFraction = 0.25
        static let mergeGap = 40            // epochs
        static let minSleep = 120           // epochs (main night)
        // cycles
        static let troughProminence = 0.25
        static let remEndScore = 1.0
        static let cycleMin: Double = 65 * 60
        static let cycleMax: Double = 120 * 60
        static let lastMargin: Double = 10 * 60
    }
}

// MARK: - small helpers (mirrored in the reference)

enum Stats {
    static func mean(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return .nan }
        var s = 0.0
        for x in v { s += x }
        return s / Double(v.count)
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func std(_ v: [Double], ddof: Int) -> Double {
        let n = v.count
        guard n - ddof > 0 else { return .nan }
        var m = 0.0
        for x in v { m += x }
        m /= Double(n)
        var s = 0.0
        for x in v { s += (x - m) * (x - m) }
        return (s / Double(n - ddof)).squareRoot()
    }

    /// fn over the valid (non-NaN) values in [i-half, i+half] when at least `minimum` are valid, else NaN
    static func centered(_ values: [Double], half: Int, minimum: Int, _ fn: ([Double]) -> Double) -> [Double] {
        let n = values.count
        var out = [Double](repeating: .nan, count: n)
        var w: [Double] = []
        w.reserveCapacity(2 * half + 1)
        for i in 0..<n {
            w.removeAll(keepingCapacity: true)
            for j in max(0, i - half)..<min(n, i + half + 1) where !values[j].isNaN { w.append(values[j]) }
            if w.count >= minimum { out[i] = fn(w) }
        }
        return out
    }

    /// z-scores against the valid values where `mask` is true; with fewer than two of them, valid values become 0
    static func zscore(_ values: [Double], mask: [Bool]) -> [Double] {
        var sel: [Double] = []
        for i in values.indices where mask[i] && !values[i].isNaN { sel.append(values[i]) }
        if sel.count < 2 { return values.map { $0.isNaN ? .nan : 0 } }
        let mu = mean(sel)
        let sd = std(sel, ddof: 1) + 1e-9
        return values.map { $0.isNaN ? .nan : ($0 - mu) / sd }
    }

    /// Python's max(a, b): keeps `a` unless `b` is greater (so a NaN `a` stays)
    @inline(__always) static func pyMax(_ a: Double, _ b: Double) -> Double { b > a ? b : a }
}

// MARK: - breathing

enum Breathing {
    private static let n = NightAnalysis.Params.breathN
    private static let hann: [Double] = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
    private static let cosTable: [[Double]] = NightAnalysis.Params.breathBins.map { j in (0..<n).map { cos(2 * Double.pi * Double(j) * Double($0) / Double(n)) } }
    private static let sinTable: [[Double]] = NightAnalysis.Params.breathBins.map { j in (0..<n).map { sin(2 * Double.pi * Double(j) * Double($0) / Double(n)) } }

    /// breaths per minute from 600 samples (60 s at 10 Hz) starting at `i0` of the grid, or NaN (moving, gap, no clear rhythm)
    static func rate(_ g: Grid10, from i0: Int) -> Double {
        guard i0 >= 0, i0 + n <= g.count else { return .nan }
        let axes = [Array(g.x[i0..<i0 + n]), Array(g.y[i0..<i0 + n]), Array(g.z[i0..<i0 + n])]
        for v in axes where v.contains(where: \.isNaN) { return .nan }
        for v in axes where Stats.std(v, ddof: 0) > NightAnalysis.Params.breathStill { return .nan }
        let bins = NightAnalysis.Params.breathBins
        var best: (power: Double, rate: Double, prominence: Double)? = nil
        let mx = Double(n - 1) / 2
        var sxx = 0.0
        for i in 0..<n { sxx += (Double(i) - mx) * (Double(i) - mx) }
        var y = [Double](repeating: 0, count: n)
        for v in axes {
            var my = 0.0
            for x in v { my += x }
            my /= Double(n)
            var sxy = 0.0
            for i in 0..<n { sxy += (Double(i) - mx) * (v[i] - my) }
            let slope = sxy / sxx
            for i in 0..<n { y[i] = (v[i] - (my + slope * (Double(i) - mx))) * hann[i] }
            var p = [Double](repeating: 0, count: bins.count)
            for b in bins.indices {
                var re = 0.0, im = 0.0
                let cs = cosTable[b], sn = sinTable[b]
                for i in 0..<n { re += y[i] * cs[i] }
                for i in 0..<n { im += y[i] * sn[i] }
                p[b] = re * re + im * im
            }
            var m = 0
            for b in 1..<p.count where p[b] > p[m] { m = b }          // first maximum
            let prominence = p[m] / (Stats.median(p) + 1e-12)
            var f = Double(bins[m]) / 60
            if m > 0 && m < p.count - 1 {
                let a = log(p[m - 1] + 1e-18), bb = log(p[m] + 1e-18), c = log(p[m + 1] + 1e-18)
                let den = a - 2 * bb + c
                if den != 0 { f += 0.5 * (a - c) / den / 60 }
            }
            if best == nil || p[m] > best!.power { best = (p[m], f * 60, prominence) }
        }
        guard let b = best, b.prominence > NightAnalysis.Params.breathProminence else { return .nan }
        return b.rate
    }
}

// MARK: - the analysis

extension NightAnalysis {
    /// Analyses [lo, hi). With `onset` and `wake` given (Apple Health, an alarm) they set the sleep window; otherwise
    /// the longest quiet stretch is taken. Returns nil when no sleep is found.
    static func analyze(seconds sec: SecondSeries, heart: HeartSeries, grid: Grid10?, charging: [Double],
                        from lo: Double, to hi: Double, onset givenOnset: Double? = nil, wake givenWake: Double? = nil,
                        minSleepEpochs: Int = Params.minSleep) -> NightAnalysis? {
        let E = Params.epoch
        let e0 = (lo / E).rounded(.down) * E
        let n = Int(((hi - e0) / E).rounded(.up))
        guard n > 0 else { return nil }
        let starts = (0..<n).map { e0 + Double($0) * E }

        // motion per epoch
        var nsec = [Int](repeating: 0, count: n)
        var movs = [Int](repeating: 0, count: n)
        var gsum = [[Double]](repeating: [0, 0, 0], count: n)
        for i in 0..<sec.count {
            let k = Int(((sec.t[i] - e0) / E).rounded(.down))
            guard k >= 0 && k < n else { continue }
            nsec[k] += 1
            if sec.sd[i] > Params.moveSD { movs[k] += 1 }
            gsum[k][0] += sec.gx[i]; gsum[k][1] += sec.gy[i]; gsum[k][2] += sec.gz[i]
        }
        var grav = [[Double]?](repeating: nil, count: n)
        for k in 0..<n where nsec[k] > 0 {
            let g = gsum[k]
            let norm = (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
            if norm > 0 { grav[k] = g.map { $0 / norm } }
        }
        var posture = [Bool](repeating: false, count: n)
        if n > 2 {
            for k in 2..<n {
                if let a = grav[k], let b = grav[k - 2] {
                    let dot = max(-1, min(1, a[0] * b[0] + a[1] * b[1] + a[2] * b[2]))
                    posture[k] = acos(dot) * 180 / .pi > Params.postureDegrees
                }
            }
        }
        let moving = (0..<n).map { movs[$0] >= Params.movingSeconds || posture[$0] }

        var chargingEpoch = [Bool](repeating: false, count: n)
        for t in charging {
            let a = Int(((t - 60 - e0) / E).rounded(.down)), b = Int(((t + 60 - e0) / E).rounded(.down))
            guard b >= 0 && a < n else { continue }
            for k in max(0, a)...min(n - 1, b) { chargingEpoch[k] = true }
        }

        // heart: trend (median ±5 min), irregularity (mean |bpm - trend| ±2.5 min)
        let ht = heart.t, hb = heart.bpm
        var irr = [Double](repeating: .nan, count: ht.count)
        if !ht.isEmpty {
            var trend = [Double](repeating: .nan, count: ht.count)
            var a = 0, b = 0
            for i in ht.indices {
                while ht[a] < ht[i] - 300 { a += 1 }
                while b < ht.count && ht[b] <= ht[i] + 300 { b += 1 }
                if b - a >= 5 { trend[i] = Stats.median(Array(hb[a..<b])) }
            }
            let resid = ht.indices.map { trend[$0].isNaN ? Double.nan : abs(hb[$0] - trend[$0]) }
            a = 0; b = 0
            for i in ht.indices {
                while ht[a] < ht[i] - 150 { a += 1 }
                while b < ht.count && ht[b] <= ht[i] + 150 { b += 1 }
                let w = resid[a..<b].filter { !$0.isNaN }
                if w.count >= 8 { irr[i] = Stats.mean(Array(w)) }
            }
        }
        var hr = [Double](repeating: .nan, count: n)
        var hrIrr = [Double](repeating: .nan, count: n)
        var hsum = [Double](repeating: 0, count: n), isum = hsum
        var hcnt = [Int](repeating: 0, count: n), icnt = hcnt
        for i in ht.indices {
            let k = Int(((ht[i] - e0) / E).rounded(.down))
            guard k >= 0 && k < n else { continue }
            hsum[k] += hb[i]; hcnt[k] += 1
            if !irr[i].isNaN { isum[k] += irr[i]; icnt[k] += 1 }
        }
        for k in 0..<n {
            if hcnt[k] > 0 { hr[k] = hsum[k] / Double(hcnt[k]) }
            if icnt[k] > 0 { hrIrr[k] = isum[k] / Double(icnt[k]) }
        }

        // breathing
        var breaths = [Double](repeating: .nan, count: n)
        if let g = grid, g.count > 0 {
            for k in 0..<n {
                let i0 = Int(((starts[k] - 15 - g.start) * 10).rounded(.toNearestOrEven))
                breaths[k] = Breathing.rate(g, from: i0)
            }
        }
        let breathIrr = Stats.centered(breaths, half: 5, minimum: 4) { Stats.std($0, ddof: 1) }

        // sleep window
        var foundOnset = givenOnset, foundWake = givenWake
        if foundOnset == nil || foundWake == nil {
            let runs = quietRuns(nsec: nsec, moving: moving, charging: chargingEpoch)
            var best: (Int, Int)? = nil
            for r in runs where best == nil || (r.1 - r.0) > (best!.1 - best!.0) { best = r }
            if let r = best, r.1 - r.0 >= minSleepEpochs {
                if foundOnset == nil { foundOnset = starts[r.0] }
                if foundWake == nil { foundWake = starts[r.1 - 1] + E }
            }
        }
        guard let onset = foundOnset, let wake = foundWake, wake > onset else { return nil }
        let sl = starts.map { $0 >= onset && $0 < wake }

        // stages
        let fillIrr = Stats.median((0..<n).filter { sl[$0] && !hrIrr[$0].isNaN }.map { hrIrr[$0] })
        let irrF = hrIrr.map { $0.isNaN ? fillIrr : $0 }
        let haveBreath = (0..<n).filter { sl[$0] && !breathIrr[$0].isNaN }.count >= 20
        var zbRaw = [Double](repeating: 0, count: n)
        if haveBreath {
            var logb = breathIrr.map { (!$0.isNaN && $0 > 0) ? log($0) : Double.nan }
            let fillB = Stats.median((0..<n).filter { sl[$0] && !logb[$0].isNaN }.map { logb[$0] })
            logb = logb.map { $0.isNaN ? fillB : $0 }
            zbRaw = Stats.zscore(logb, mask: sl)
        }
        let ziRaw = Stats.zscore(irrF, mask: sl)
        let zi = Stats.centered(ziRaw, half: 3, minimum: 1, Stats.mean)
        let zb = Stats.centered(zbRaw, half: 3, minimum: 1, Stats.mean)
        let hrS = Stats.centered(hr, half: 3, minimum: 1, Stats.mean)
        let base = Stats.centered(hr, half: 60, minimum: 30, Stats.median)
        let det = (0..<n).map { (hrS[$0].isNaN || base[$0].isNaN) ? Double.nan : hrS[$0] - base[$0] }
        let zd = Stats.zscore(det, mask: sl).map { $0.isNaN ? 0 : $0 }
        func sumMovs(_ k: Int, _ half: Int) -> Int {
            var s = 0
            for j in max(0, k - half)..<min(n, k + half + 1) { s += movs[j] }
            return s
        }
        let strong = movs.map { $0 >= Params.awakeSeconds ? 1 : 0 }

        var stage = [SleepStage](repeating: .awake, count: n)
        for k in 0..<n where sl[k] {
            var s = SleepStage.light
            let mins = (starts[k] - onset) / 60
            let deep = sumMovs(k, 4) == 0 && zi[k] < -0.4 && zb[k] < 0 && zd[k] < 0.5
            let rem = sumMovs(k, 2) <= 2 && Stats.pyMax(zi[k], zb[k]) > 0.35 && mins > 50 && !deep
            if deep { s = .deep } else if rem { s = .rem }
            var st = 0
            for j in max(0, k - 1)..<min(n, k + 2) { st += strong[j] }
            if st >= 2 { s = .awake }
            stage[k] = s
        }
        var filtered = stage
        for k in 0..<n where sl[k] && stage[k] != .awake {
            var counts = [0, 0, 0, 0]
            for j in max(0, k - 3)..<min(n, k + 4) where sl[j] && stage[j] != .awake { counts[stage[j].rawValue] += 1 }
            var bestStage = 1
            for s in 2...3 where counts[s] > counts[bestStage] { bestStage = s }
            filtered[k] = SleepStage(rawValue: bestStage)!
        }
        stage = filtered

        // depth wave and cycles
        let movf = Stats.centered(moving.map { $0 ? 1.0 : 0.0 }, half: 5, minimum: 1, Stats.mean)
        let zm = Stats.zscore(movf, mask: sl)
        var rawDepth = [Double](repeating: .nan, count: n)
        for k in 0..<n where sl[k] { rawDepth[k] = -(ziRaw[k] + zbRaw[k] + zm[k] + 0.5 * zd[k]) / 3.5 }
        let depth = Stats.centered(rawDepth, half: 10, minimum: 6, Stats.mean)
        let ks = (0..<n).filter { sl[$0] }
        let inv = ks.map { depth[$0].isNaN ? -1e9 : -depth[$0] }
        var cands: [Int: Double] = [:]
        for (i, prom) in troughsWithProminence(inv) where prom >= Params.troughProminence {
            cands[ks[i]] = max(cands[ks[i]] ?? 0, prom)
        }
        var blocks: [(Int, Int)] = []
        var k = 0
        while k < n {
            if sl[k] && stage[k] == .rem {
                var j = k
                while j < n && sl[j] && stage[j] == .rem { j += 1 }
                if let last = blocks.last, k - last.1 < 10 { blocks[blocks.count - 1].1 = j } else { blocks.append((k, j)) }
                k = j
            } else { k += 1 }
        }
        for (b0, b1) in blocks where b1 - b0 >= 8 && b1 < n {
            cands[b1] = max(cands[b1] ?? 0, Params.remEndScore)
        }
        let sortedCands = cands.map { (starts[$0.key], $0.value) }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let bounds = [onset] + cycleBounds(sortedCands, onset: onset, wake: wake) + [wake]

        var cycles: [Cycle] = []
        for i in 0..<(bounds.count - 1) {
            let a = bounds[i], b = bounds[i + 1]
            var mins = [0.0, 0.0, 0.0, 0.0]
            for k in 0..<n where sl[k] && starts[k] >= a && starts[k] < b { mins[stage[k].rawValue] += E / 60 }
            cycles.append(Cycle(start: a, end: b, complete: b != wake || (b - a) >= 80 * 60, stages: mins))
        }

        // summary
        var stageMin = [0.0, 0.0, 0.0, 0.0]
        for k in 0..<n where sl[k] { stageMin[stage[k].rawValue] += E / 60 }
        let hsIdx = ht.indices.filter { ht[$0] >= onset && ht[$0] < wake }
        var low5 = Double.nan, low5At: Double? = nil
        var a = 0
        for (pos, i) in hsIdx.enumerated() {
            while ht[hsIdx[a]] < ht[i] - 300 { a += 1 }
            if pos - a + 1 >= 10 {
                let m = Stats.median(hsIdx[a...pos].map { hb[$0] })
                if low5.isNaN || m < low5 { low5 = m; low5At = ht[i] }
            }
        }
        let br = (0..<n).filter { sl[$0] && !breaths[$0].isNaN }.map { breaths[$0] }
        var bursts = 0
        var lastMove: Double? = nil
        for i in 0..<sec.count where sec.t[i] >= onset && sec.t[i] < wake && sec.sd[i] > Params.moveSD {
            if lastMove == nil || sec.t[i] - lastMove! > 30 { bursts += 1 }
            lastMove = sec.t[i]
        }
        let hrVals = hsIdx.map { hb[$0] }
        let summary = Summary(minutes: (wake - onset) / 60, stages: stageMin,
                              hrMean: hrVals.isEmpty ? nil : Stats.mean(hrVals), hrMin: hrVals.min(),
                              hrLow5: low5.isNaN ? nil : low5, hrLow5At: low5At,
                              breaths: br.isEmpty ? nil : Stats.median(br), bursts: bursts)
        return NightAnalysis(onset: onset, wake: wake, epochStart: e0, stage: stage, depth: depth, heart: hr,
                             breaths: breaths, movingSeconds: movs, cycles: cycles, summary: summary)
    }

    /// Quiet stretches as epoch ranges [start, end): an epoch is quiet when it has data, is not on the charger and
    /// fewer than a quarter of the valid epochs within ±10 are moving; stretches less than 20 minutes apart merge.
    static func quietRuns(nsec: [Int], moving: [Bool], charging: [Bool]) -> [(Int, Int)] {
        let n = nsec.count
        let valid = (0..<n).map { nsec[$0] >= 15 && !charging[$0] }
        var quiet = [Bool](repeating: false, count: n)
        for k in 0..<n {
            var cnt = 0, mov = 0
            for j in max(0, k - 10)..<min(n, k + 11) where valid[j] {
                cnt += 1
                if moving[j] { mov += 1 }
            }
            quiet[k] = valid[k] && cnt >= 10 && Double(mov) / Double(cnt) < Params.quietFraction
        }
        var runs: [(Int, Int)] = []
        var k = 0
        while k < n {
            if quiet[k] {
                var j = k
                while j < n && quiet[j] { j += 1 }
                if let last = runs.last, k - last.1 < Params.mergeGap { runs[runs.count - 1].1 = j } else { runs.append((k, j)) }
                k = j
            } else { k += 1 }
        }
        return runs
    }

    /// Per-epoch motion (count of seconds, moving seconds, moving flag) and charging flags, as analyze() builds them.
    static func epochMotion(_ sec: SecondSeries, charging: [Double], e0: Double, n: Int) -> (nsec: [Int], movs: [Int], moving: [Bool], charging: [Bool]) {
        let E = Params.epoch
        var nsec = [Int](repeating: 0, count: n)
        var movs = [Int](repeating: 0, count: n)
        var gsum = [[Double]](repeating: [0, 0, 0], count: n)
        for i in 0..<sec.count {
            let k = Int(((sec.t[i] - e0) / E).rounded(.down))
            guard k >= 0 && k < n else { continue }
            nsec[k] += 1
            if sec.sd[i] > Params.moveSD { movs[k] += 1 }
            gsum[k][0] += sec.gx[i]; gsum[k][1] += sec.gy[i]; gsum[k][2] += sec.gz[i]
        }
        var grav = [[Double]?](repeating: nil, count: n)
        for k in 0..<n where nsec[k] > 0 {
            let g = gsum[k]
            let norm = (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
            if norm > 0 { grav[k] = g.map { $0 / norm } }
        }
        var moving = [Bool](repeating: false, count: n)
        for k in 0..<n {
            var posture = false
            if k >= 2, let a = grav[k], let b = grav[k - 2] {
                let dot = max(-1, min(1, a[0] * b[0] + a[1] * b[1] + a[2] * b[2]))
                posture = acos(dot) * 180 / .pi > Params.postureDegrees
            }
            moving[k] = movs[k] >= Params.movingSeconds || posture
        }
        var chargingEpoch = [Bool](repeating: false, count: n)
        for t in charging {
            let a = Int(((t - 60 - e0) / E).rounded(.down)), b = Int(((t + 60 - e0) / E).rounded(.down))
            guard b >= 0 && a < n else { continue }
            for k in max(0, a)...min(n - 1, b) { chargingEpoch[k] = true }
        }
        return (nsec, movs, moving, chargingEpoch)
    }

    /// Every sleep in [lo, hi) of at least `minMinutes`: the quiet stretches, as (onset, wake).
    static func sleepPeriods(seconds sec: SecondSeries, charging: [Double], from lo: Double, to hi: Double,
                             minMinutes: Double = 20) -> [(onset: Double, wake: Double)] {
        let E = Params.epoch
        let e0 = (lo / E).rounded(.down) * E
        let n = Int(((hi - e0) / E).rounded(.up))
        guard n > 0 else { return [] }
        let m = epochMotion(sec, charging: charging, e0: e0, n: n)
        let minEpochs = Int((minMinutes * 60 / E).rounded(.up))
        return quietRuns(nsec: m.nsec, moving: m.moving, charging: m.charging)
            .filter { $0.1 - $0.0 >= minEpochs }
            .map { (e0 + Double($0.0) * E, e0 + Double($0.1) * E) }
    }

    /// (index, prominence) of every local maximum (plateaus: their middle), prominence as in scipy
    static func troughsWithProminence(_ x: [Double]) -> [(Int, Double)] {
        let n = x.count
        var out: [(Int, Double)] = []
        var i = 1
        while i < n - 1 {
            if x[i - 1] < x[i] {
                var j = i
                while j + 1 < n && x[j + 1] == x[i] { j += 1 }
                if j + 1 < n && x[j + 1] < x[i] {
                    let p = (i + j) / 2
                    var lo = p, lmin = x[p]
                    while lo > 0 && x[lo - 1] <= x[p] { lo -= 1; lmin = min(lmin, x[lo]) }
                    var hi = p, rmin = x[p]
                    while hi < n - 1 && x[hi + 1] <= x[p] { hi += 1; rmin = min(rmin, x[hi]) }
                    out.append((p, x[p] - max(lmin, rmin)))
                }
                i = j + 1
            } else { i += 1 }
        }
        return out
    }

    /// Boundaries from (time, score) candidates: every full cycle lasts cycleMin...cycleMax, the last part up to the
    /// wake at most cycleMax; the chain with the highest summed score wins (ties: more boundaries, then earlier ones).
    static func cycleBounds(_ all: [(Double, Double)], onset: Double, wake: Double) -> [Double] {
        let cands = all.filter { $0.0 >= onset + Params.cycleMin && $0.0 <= wake - Params.lastMargin }
        typealias Chain = (score: Double, count: Int, times: [Double])
        func better(_ a: Chain, _ b: Chain) -> Bool {          // is a preferred over b?
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            if a.count != b.count { return a.count > b.count }
            for (x, y) in zip(a.times, b.times) where x != y { return x < y }
            return false
        }
        var best: [Int: Chain] = [:]
        for (i, c) in cands.enumerated() {
            var top: Chain? = nil
            if c.0 - onset >= Params.cycleMin && c.0 - onset <= Params.cycleMax { top = (c.1, 1, [c.0]) }
            for j in 0..<i {
                guard let b = best[j] else { continue }
                let gap = c.0 - cands[j].0
                guard gap >= Params.cycleMin && gap <= Params.cycleMax else { continue }
                let o: Chain = (b.score + c.1, b.count + 1, b.times + [c.0])
                if top == nil || better(o, top!) { top = o }
            }
            if let top { best[i] = top }
        }
        var final: Chain? = nil
        for i in best.keys.sorted() where wake - cands[i].0 <= Params.cycleMax {
            if final == nil || better(best[i]!, final!) { final = best[i] }
        }
        return final?.times ?? []
    }
}
