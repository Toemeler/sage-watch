import Foundation

/// Breathing from a resting wrist. When the arm lies on the chest or belly, every breath tilts the watch by a degree or
/// two, which shows as a slow wave in the direction of gravity. Feed it the watch's acceleration (in g) 10 times a second.
///
/// Steps: ignore anything while the arm moves; keep only slow waves (a ~4 s baseline is removed, a ~0.5 s smoothing
/// drops the heartbeat and noise); project onto the direction the wrist rocks the most (power iteration on the last
/// 30 s); find the period by autocorrelation (2–12 s, so 5–30 breaths a minute); mark the top of each breath.
struct BreathingDetector {
    static let hz = 10.0
    static let window = 300                      // 30 s analysed
    static let minimum = 150                     // 15 s before the first rate

    /// filtered breathing signal in milli-g, oldest first, at most `window` samples
    private(set) var wave: [Double] = []
    /// indices into `wave` of the breath tops
    private(set) var peaks: [Int] = []
    /// median of the last estimates; nil while no steady rhythm is found
    private(set) var breathsPerMinute: Double?
    /// true while the arm moves too much to see breathing
    private(set) var moving = false
    /// how clearly the rhythm repeats (autocorrelation at the breathing period, 0…1)
    private(set) var clarity = 0.0

    private var slow: Vec?
    private var fast1: Vec?
    private var fast2: Vec?
    private var band: [Vec] = []
    private var axis = Vec(0, 0, 1)
    private var magnitudes: [Double] = []
    private var sinceUpdate = 0
    private var estimates: [Double] = []

    mutating func add(x: Double, y: Double, z: Double) {
        let v = Vec(x, y, z)
        magnitudes.append(v.length)
        if magnitudes.count > 20 { magnitudes.removeFirst(magnitudes.count - 20) }
        // a twitch or a turn changes the size of the acceleration; breathing only tilts it
        if magnitudes.count >= 10 && Self.sd(magnitudes) > 0.015 {
            restart(moving: true, at: v)
            return
        }
        moving = false

        let s0 = slow ?? v
        let s = s0 + (v - s0) * 0.025                        // ~4 s baseline: the resting posture and slow drift
        slow = s
        let a0 = fast1 ?? v
        let a = a0 + (v - a0) * 0.3                          // two ~0.3 s smoothings: heartbeat and noise out
        fast1 = a
        let b0 = fast2 ?? a
        let b = b0 + (a - b0) * 0.3
        fast2 = b
        let d = b - s
        if d.length > 0.15 {                                 // a slow change of posture, not a breath: start over
            restart(moving: false, at: v)
            return
        }
        band.append(d)
        if band.count > Self.window { band.removeFirst(band.count - Self.window) }

        sinceUpdate += 1
        if sinceUpdate >= 10 || band.count < 50 {
            sinceUpdate = 0
            analyse()
        } else {
            wave.append(d.dot(axis) * 1000)
            if wave.count > Self.window { wave.removeFirst(wave.count - Self.window) }
        }
    }

    private mutating func restart(moving: Bool, at v: Vec) {
        self.moving = moving
        slow = v; fast1 = v; fast2 = v
        band.removeAll(); wave.removeAll(); peaks.removeAll(); estimates.removeAll()
        breathsPerMinute = nil
        clarity = 0
        sinceUpdate = 0
    }

    private mutating func analyse() {
        if band.count >= 50 { axis = Self.mainAxis(band, start: axis) }
        wave = band.map { $0.dot(axis) * 1000 }
        guard wave.count >= Self.minimum else { peaks = []; breathsPerMinute = nil; clarity = 0; return }

        let mean = wave.reduce(0, +) / Double(wave.count)
        let x = wave.map { $0 - mean }
        let energy = x.reduce(0) { $0 + $1 * $1 } / Double(x.count)
        guard energy > 1e-6 else { peaks = []; breathsPerMinute = nil; clarity = 0; return }
        let lags = 20...120                                   // 2–12 s
        var r = [Double](repeating: 0, count: lags.upperBound + 2)
        for lag in (lags.lowerBound - 1)...(lags.upperBound + 1) where lag < x.count {
            var s = 0.0
            for i in 0..<(x.count - lag) { s += x[i] * x[i + lag] }
            r[lag] = s / Double(x.count - lag) / energy
        }
        var tops: [Int] = []
        for lag in lags where lag + 1 < x.count && r[lag] > r[lag - 1] && r[lag] >= r[lag + 1] { tops.append(lag) }
        guard let best = tops.map({ r[$0] }).max(), best > 0.3,
              let lag = tops.first(where: { r[$0] >= 0.8 * best }) else {
            clarity = max(0, tops.map { r[$0] }.max() ?? 0)
            estimates.removeAll()
            breathsPerMinute = nil
            peaks = []
            return
        }
        clarity = r[lag]
        // parabolic refinement of the period
        let y0 = r[lag - 1], y1 = r[lag], y2 = r[lag + 1]
        let den = y0 - 2 * y1 + y2
        let period = Double(lag) + (den == 0 ? 0 : 0.5 * (y0 - y2) / den)
        estimates.append(60 * Self.hz / period)
        if estimates.count > 5 { estimates.removeFirst(estimates.count - 5) }
        breathsPerMinute = estimates.sorted()[estimates.count / 2]

        let sd = energy.squareRoot()
        let gap = Int(0.6 * period)
        var found: [Int] = []
        if x.count >= 3 {
            for i in 1..<(x.count - 1) where x[i] > x[i - 1] && x[i] >= x[i + 1] && x[i] > 0.3 * sd {
                if let last = found.last, i - last < gap {
                    if x[i] > x[last] { found[found.count - 1] = i }
                } else {
                    found.append(i)
                }
            }
        }
        peaks = found
    }

    /// direction of the largest variation (power iteration on the covariance), sign kept stable between updates
    private static func mainAxis(_ v: [Vec], start: Vec) -> Vec {
        let n = Double(v.count)
        let m = v.reduce(Vec(0, 0, 0), +) * (1 / n)
        var c = [[Double]](repeating: [0, 0, 0], count: 3)
        for p in v {
            let q = [p.x - m.x, p.y - m.y, p.z - m.z]
            for i in 0..<3 { for j in 0..<3 { c[i][j] += q[i] * q[j] } }
        }
        var a = start.length > 0 ? start : Vec(0, 0, 1)
        for _ in 0..<12 {
            let b = Vec(c[0][0] * a.x + c[0][1] * a.y + c[0][2] * a.z,
                        c[1][0] * a.x + c[1][1] * a.y + c[1][2] * a.z,
                        c[2][0] * a.x + c[2][1] * a.y + c[2][2] * a.z)
            let l = b.length
            guard l > 0 else { return start }
            a = b * (1 / l)
        }
        return a.dot(start) < 0 ? a * -1 : a
    }

    private static func sd(_ v: [Double]) -> Double {
        let m = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
    }

    struct Vec {
        var x, y, z: Double
        init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
        var length: Double { (x * x + y * y + z * z).squareRoot() }
        func dot(_ o: Vec) -> Double { x * o.x + y * o.y + z * o.z }
        static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y, a.z + b.z) }
        static func - (a: Vec, b: Vec) -> Vec { Vec(a.x - b.x, a.y - b.y, a.z - b.z) }
        static func * (a: Vec, k: Double) -> Vec { Vec(a.x * k, a.y * k, a.z * k) }
    }
}

/// Messages between the iPhone's live breathing screen and the watch.
enum LiveLink {
    static let commandKey = "live"        // iPhone → watch: [commandKey: breathing, onKey: true/false], repeated every few s
    static let onKey = "on"
    static let breathing = "breathing"
    static let recordingKey = "recording" // watch → iPhone in the reply: is the recorder running?
    static let samplesKey = "s"           // watch → iPhone: packed Float32 x, y, z triples at 10 Hz

    static func pack(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data) -> [(Double, Double, Double)] {
        let n = data.count / MemoryLayout<Float>.size
        guard n >= 3 else { return [] }
        var f = [Float](repeating: 0, count: n)
        _ = f.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return stride(from: 0, to: n - 2, by: 3).map { (Double(f[$0]), Double(f[$0 + 1]), Double(f[$0 + 2])) }
    }
}
