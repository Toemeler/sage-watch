import SwiftUI

/// Morphing between digit outlines, ported from the prototype:
/// contours are flattened and resampled to N points, outer contours pair with outer and holes with holes (by winding),
/// a missing contour grows from a tiny seed loop of the right winding, and each pair is rotated to its best alignment.
enum GlyphMorph {
    static let samples = 96

    struct Contour { let points: [CGPoint]; let area: Double; let centroid: CGPoint }

    // MARK: flatten + resample

    /// SVG path data -> polylines (quadratics and cubics subdivided)
    static func polylines(_ d: String) -> [[CGPoint]] {
        var out: [[CGPoint]] = [], cur: [CGPoint] = []
        var tok = SVGPath.Tokenizer(d)
        var cmd: Character = "M"
        var p = CGPoint.zero
        func flush() { if cur.count > 2 { out.append(cur) }; cur = [] }
        while let next = tok.peek() {
            if case .command(let c) = next { cmd = c; _ = tok.next() }
            let rel = cmd.isLowercase
            func pt() -> CGPoint? {
                guard let x = tok.number(), let y = tok.number() else { return nil }
                return rel ? CGPoint(x: p.x + x, y: p.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd.uppercased().first! {
            case "M":
                guard let q = pt() else { flush(); return out }
                flush(); p = q; cur = [q]; cmd = rel ? "l" : "L"
            case "L":
                guard let q = pt() else { flush(); return out }
                p = q; cur.append(q)
            case "H":
                guard let x = tok.number() else { flush(); return out }
                p = CGPoint(x: rel ? p.x + x : x, y: p.y); cur.append(p)
            case "V":
                guard let y = tok.number() else { flush(); return out }
                p = CGPoint(x: p.x, y: rel ? p.y + y : y); cur.append(p)
            case "Q":
                guard let c = pt(), let q = pt() else { flush(); return out }
                for i in 1...8 { let t = Double(i) / 8, u = 1 - t
                    cur.append(CGPoint(x: u * u * p.x + 2 * u * t * c.x + t * t * q.x, y: u * u * p.y + 2 * u * t * c.y + t * t * q.y)) }
                p = q
            case "C":
                guard let c1 = pt(), let c2 = pt(), let q = pt() else { flush(); return out }
                for i in 1...12 { let t = Double(i) / 12, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, e = t * t * t
                    cur.append(CGPoint(x: a * p.x + b * c1.x + c * c2.x + e * q.x, y: a * p.y + b * c1.y + c * c2.y + e * q.y)) }
                p = q
            case "Z":
                flush()
            default:
                _ = tok.next()
            }
        }
        flush()
        return out
    }

    /// resample a closed polyline to `n` points evenly spaced by arc length
    static func resample(_ poly: [CGPoint], _ n: Int = samples) -> [CGPoint] {
        guard poly.count > 1 else { return Array(repeating: poly.first ?? .zero, count: n) }
        var pts = poly; if pts.first != pts.last { pts.append(pts[0]) }
        var cum: [Double] = [0]
        for i in 1..<pts.count { cum.append(cum[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = cum.last!
        guard total > 0 else { return Array(repeating: pts[0], count: n) }
        var out: [CGPoint] = [], j = 1
        for k in 0..<n {
            let s = total * Double(k) / Double(n)
            while j < cum.count - 1 && cum[j] < s { j += 1 }
            let seg = cum[j] - cum[j - 1], t = seg > 0 ? (s - cum[j - 1]) / seg : 0
            out.append(CGPoint(x: pts[j - 1].x + (pts[j].x - pts[j - 1].x) * t, y: pts[j - 1].y + (pts[j].y - pts[j - 1].y) * t))
        }
        return out
    }

    static func contour(_ pts: [CGPoint]) -> Contour {
        var a = 0.0, cx = 0.0, cy = 0.0
        for i in 0..<pts.count {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            a += p.x * q.y - q.x * p.y; cx += p.x; cy += p.y
        }
        return Contour(points: pts, area: a / 2, centroid: CGPoint(x: cx / Double(pts.count), y: cy / Double(pts.count)))
    }

    // MARK: pairing

    typealias Pair = ([CGPoint], [CGPoint])

    static func pair(_ A: [Contour], _ B: [Contour]) -> [Pair] {
        func sign(_ cs: [Contour]) -> Double { (cs.max { abs($0.area) < abs($1.area) }?.area ?? 1).sign == .minus ? -1 : 1 }
        func split(_ cs: [Contour]) -> ([Contour], [Contour]) {
            let s = sign(cs)
            let outer = cs.filter { ($0.area < 0 ? -1.0 : 1.0) == s }.sorted { abs($0.area) > abs($1.area) }
            let holes = cs.filter { ($0.area < 0 ? -1.0 : 1.0) != s }.sorted { abs($0.area) > abs($1.area) }
            return (outer, holes)
        }
        func seed(_ c: Contour) -> [CGPoint] {
            let wind: Double = c.area < 0 ? -1 : 1, r = 1.5
            return (0..<samples).map { i in let t = wind * Double(i) / Double(samples) * 2 * .pi
                return CGPoint(x: c.centroid.x + cos(t) * r, y: c.centroid.y + sin(t) * r) }
        }
        func bestShift(_ pa: [CGPoint], _ pb: [CGPoint]) -> [CGPoint] {
            var best = 0, bestD = Double.infinity
            for k in stride(from: 0, to: samples, by: 2) {
                var d = 0.0
                for i in stride(from: 0, to: samples, by: 6) { let p = pa[i], q = pb[(i + k) % samples]; d += (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) }
                if d < bestD { bestD = d; best = k }
            }
            return (0..<samples).map { pb[($0 + best) % samples] }
        }
        let (ao, ah) = split(A), (bo, bh) = split(B)
        var out: [Pair] = []
        for (ga, gb) in [(ao, bo), (ah, bh)] {
            for i in 0..<max(ga.count, gb.count) {
                let ca = i < ga.count ? ga[i] : nil, cb = i < gb.count ? gb[i] : nil
                guard let any = ca ?? cb else { continue }
                let pa = ca?.points ?? seed(cb ?? any), pb = cb?.points ?? seed(ca ?? any)
                out.append((pa, bestShift(pa, pb)))
            }
        }
        return out
    }

    /// path between two paired outlines at t (0 = from, 1 = to)
    static func path(_ pairs: [Pair], _ t: Double) -> Path {
        var p = Path()
        for (a, b) in pairs {
            for i in 0..<a.count {
                let q = CGPoint(x: a[i].x + (b[i].x - a[i].x) * t, y: a[i].y + (b[i].y - a[i].y) * t)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
        }
        return p
    }

    // MARK: cache

    private static var contourCache: [String: [Contour]] = [:]
    private static var pairCache: [String: [Pair]] = [:]
    private static let lock = NSLock()

    static func contours(_ set: GlyphSet, _ digit: Int) -> [Contour] {
        let key = "\(ObjectIdentifier(set).hashValue)-\(digit)"
        lock.lock(); defer { lock.unlock() }
        if let c = contourCache[key] { return c }
        let c = (set.sources[digit].map { polylines($0) } ?? []).map { contour(resample($0)) }
        contourCache[key] = c
        return c
    }

    static func pairs(_ set: GlyphSet, from a: Int, to b: Int) -> [Pair] {
        let key = "\(ObjectIdentifier(set).hashValue)-\(a)-\(b)"
        lock.lock(); if let p = pairCache[key] { lock.unlock(); return p }; lock.unlock()
        let p = pair(contours(set, a), contours(set, b))
        lock.lock(); pairCache[key] = p; lock.unlock()
        return p
    }

    /// escapement easing from the prototype: fast travel, hard stop, small overshoot that settles
    static func escape(_ t: Double) -> Double {
        if t >= 1 { return 1 }
        let x = min(max(t, 0), 1), s = 2.2
        return 1 + (s + 1) * pow(x - 1, 3) + s * pow(x - 1, 2)
    }
}
