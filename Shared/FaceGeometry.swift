import SwiftUI

/// Geometry of the face in the reference coordinate space (the screen is x 131...827, y 63...893).
/// Everything is ported 1:1 from the browser prototype (face.js / anim.js).
enum FaceGeometry {
    static let screen = CGRect(x: 131, y: 63, width: 696, height: 830)
    static let dialCentre = CGPoint(x: 480.5, y: 478)
    static let disc = (centre: CGPoint(x: 482, y: 418), r: 182.0)

    enum Palette {
        static let ivory = Color(hex: 0xE2D9C9), sage = Color(hex: 0x8C9A7E), sageLight = Color(hex: 0xB9C4AA)
        static let sageDark = Color(hex: 0x55604B), num = Color(hex: 0xADB19D), track = Color(hex: 0x43443E)
        static let text = Color(hex: 0xCFCBBB), icon = Color(hex: 0xADB39D), rim = Color(hex: 0x8A917C)
        static let gold = Color(hex: 0xC9A877)
    }

    /// 13 applied indices: centre, rotation (deg), length, width
    static let indices: [(CGPoint, Double, Double, Double)] = [
        (CGPoint(x: 475, y: 118), 0, 71, 15), (CGPoint(x: 492.5, y: 118), 0, 71, 15), (CGPoint(x: 698, y: 122), 30, 64, 18),
        (CGPoint(x: 781, y: 293.5), 90, 54, 17.5), (CGPoint(x: 781, y: 467), 90, 54, 17.5), (CGPoint(x: 781, y: 646.5), 90, 54, 17.5),
        (CGPoint(x: 704, y: 834), -30, 64, 18), (CGPoint(x: 484.5, y: 852), 0, 48.5, 19), (CGPoint(x: 264, y: 834), 30, 64, 18),
        (CGPoint(x: 180.5, y: 646.5), 90, 54, 17.5), (CGPoint(x: 180.5, y: 467), 90, 54, 17.5), (CGPoint(x: 180.5, y: 293.5), 90, 54, 17.5),
        (CGPoint(x: 266, y: 122), -30, 64, 18)
    ]
    /// minute numerals
    static let numerals: [(CGPoint, String)] = [
        (CGPoint(x: 299, y: 190.5), "55"), (CGPoint(x: 670, y: 190.5), "05"), (CGPoint(x: 241, y: 332.5), "50"), (CGPoint(x: 731, y: 334), "10"),
        (CGPoint(x: 241, y: 603.5), "40"), (CGPoint(x: 730, y: 603.5), "20"), (CGPoint(x: 299.5, y: 774), "35"), (CGPoint(x: 670, y: 774), "25")
    ]

    /// rounded-rect railway track (outer and inner rail)
    struct RoundedTrack {
        let rect: CGRect, radius: Double
        func sdf(_ p: CGPoint) -> Double {
            let hx = rect.width / 2, hy = rect.height / 2
            let qx = abs(p.x - rect.midX) - (hx - radius), qy = abs(p.y - rect.midY) - (hy - radius)
            return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
        }
        /// point on the rail in direction t (0 = up, clockwise) seen from c, plus the outward normal
        func hit(_ t: Double, from c: CGPoint) -> (CGPoint, CGVector) {
            let dx = sin(t), dy = -cos(t)
            var lo = 0.0, hi = 900.0
            for _ in 0..<45 { let m = (lo + hi) / 2; if sdf(CGPoint(x: c.x + dx * m, y: c.y + dy * m)) < 0 { lo = m } else { hi = m } }
            let p = CGPoint(x: c.x + dx * lo, y: c.y + dy * lo), e = 0.05
            var nx = sdf(CGPoint(x: p.x + e, y: p.y)) - sdf(CGPoint(x: p.x - e, y: p.y))
            var ny = sdf(CGPoint(x: p.x, y: p.y + e)) - sdf(CGPoint(x: p.x, y: p.y - e))
            let h = hypot(nx, ny); nx /= h; ny /= h
            return (p, CGVector(dx: nx, dy: ny))
        }
    }
    static let outerRail = RoundedTrack(rect: CGRect(x: 153.5, y: 81.5, width: 654, height: 793.5), radius: 148)
    static let innerRail = RoundedTrack(rect: CGRect(x: 181.5, y: 109.5, width: 598, height: 737.5), radius: 120)
    /// 300 tick positions around the outer rail (every 5th is a minute)
    static let ticks: [(CGPoint, CGVector)] = (0..<300).map { outerRail.hit(Double($0) / 300 * 2 * .pi, from: dialCentre) }

    /// digit slots fitted to the reference ink boxes: hours 294...471, minutes 501...722, baseline 495.5
    struct Slot { let x: Double; let scaleX: Double; let scaleY: Double; let base: Double }
    static func slots(_ set: GlyphSet, template: (Int, Int), x0: Double, x1: Double, h: Double, base: Double) -> [Slot] {
        guard let zero = set.digits[0], let a = set.digits[template.0], let b = set.digits[template.1] else { return [] }
        let z = zero.path.boundingRect, s = h / z.height
        let ba = a.path.boundingRect, bb = b.path.boundingRect
        let inkW = (a.advance + Double(bb.maxX)) - Double(ba.minX), sx = (x1 - x0) / (inkW * s)
        let ox = x0 - Double(ba.minX) * s * sx, baseY = base + Double(z.minY) * s
        return [Slot(x: ox, scaleX: s * sx, scaleY: s, base: baseY), Slot(x: ox + a.advance * s * sx, scaleX: s * sx, scaleY: s, base: baseY)]
    }
    static let hourSlots = slots(Glyphs.regular, template: (1, 0), x0: 294, x1: 471, h: 151, base: 495.5)
    static let minuteSlots = slots(Glyphs.italic, template: (0, 9), x0: 501, x1: 722, h: 153, base: 495.5)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
