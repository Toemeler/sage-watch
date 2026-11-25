import SwiftUI

/// Everything the face shows at one instant.
struct FaceState {
    var date: Date
    var mode: FaceMode
    var steps: Int?
    var heartRate: Int?
    var dimmed: Bool = false          // always-on (luminance reduced)
    var battery: Int? = nil           // watch battery in percent; nil where unknown (the plaque then shows only the bolt)
    var charging: Bool = false

    var label: String { mode.label(date) }
}

/// Draws the face into a GraphicsContext in the reference coordinate space, scaled to fill `size`.
enum FaceRenderer {
    typealias P = FaceGeometry.Palette

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, state: FaceState) {
        let src = FaceGeometry.screen
        let scale = max(size.width / src.width, size.height / src.height)
        ctx.translateBy(x: (size.width - src.width * scale) / 2, y: (size.height - src.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -src.minX, y: -src.minY)

        ctx.fill(Path(src), with: .color(.black))
        if !state.dimmed { drawDial(&ctx) }
        drawTrack(&ctx, dimmed: state.dimmed)
        if !state.dimmed { drawRunner(&ctx, state.date) }
        drawIndices(&ctx, dimmed: state.dimmed)
        if !state.dimmed { drawNumerals(&ctx) }
        if !state.dimmed { drawDate(&ctx, state.date) }
        drawTime(&ctx, state.date, dimmed: state.dimmed)
        drawLabel(&ctx, state.label, dimmed: state.dimmed)
        if !state.dimmed && state.mode != .sleeping {
            drawSubdial(&ctx, at: FaceGeometry.subdials[0], value: state.steps.map(Self.compactSteps) ?? "–", unit: nil, icon: .shoe,
                        progress: Double(state.steps ?? 0) / 10_000)
            drawSubdial(&ctx, at: FaceGeometry.subdials[1], value: state.heartRate.map(String.init) ?? "–", unit: "BPM", icon: .heart,
                        progress: Double(state.heartRate ?? 0) / 180)
            drawPlaque(&ctx, battery: state.battery, charging: state.charging)
        }
    }

    // MARK: dial

    private static func drawDial(_ ctx: inout GraphicsContext) {
        let c = FaceGeometry.disc.centre
        // sunburst: fine radial lines from the disc centre
        var rays = Path()
        for i in 0..<240 {
            let t = Double(i) / 240 * 2 * .pi
            rays.move(to: CGPoint(x: c.x + sin(t) * 30, y: c.y - cos(t) * 30))
            rays.addLine(to: CGPoint(x: c.x + sin(t) * 700, y: c.y - cos(t) * 700))
        }
        ctx.stroke(rays, with: .color(.white.opacity(0.02)), lineWidth: 0.6)
        // centre disc with guilloché rosette
        let disc = Path(ellipseIn: CGRect(x: c.x - 182, y: c.y - 182, width: 364, height: 364))
        ctx.fill(disc, with: .color(.black.opacity(0.22)))
        ctx.stroke(disc, with: .color(Color(hex: 0x262624)), lineWidth: 3.5)
        var ros = Path()
        var R = 24.0
        while R < 182 {
            for i in stride(from: 0, through: 360, by: 4) {
                let t = Double(i) * .pi / 180, r = R + 2.2 * sin(t * 18 + R * 0.09)
                let p = CGPoint(x: c.x + sin(t) * r, y: c.y - cos(t) * r)
                if i == 0 { ros.move(to: p) } else { ros.addLine(to: p) }
            }
            ros.closeSubpath(); R += 7
        }
        ctx.stroke(ros, with: .color(.white.opacity(0.035)), lineWidth: 1)
    }

    private static func drawTrack(_ ctx: inout GraphicsContext, dimmed: Bool) {
        let col = P.track.opacity(dimmed ? 0.45 : 1)
        for rail in [FaceGeometry.outerRail, FaceGeometry.innerRail] {
            ctx.stroke(Path(roundedRect: rail.rect, cornerRadius: rail.radius), with: .color(col), lineWidth: 2.2)
        }
        if dimmed { return }
        var major = Path(), minor = Path()
        for (i, (p, n)) in FaceGeometry.ticks.enumerated() {
            let len = i % 5 == 0 ? 28.0 : 9.0
            let q = CGPoint(x: p.x - n.dx * len, y: p.y - n.dy * len)
            if i % 5 == 0 { major.move(to: p); major.addLine(to: q) } else { minor.move(to: p); minor.addLine(to: q) }
        }
        ctx.stroke(major, with: .color(col), lineWidth: 2)
        ctx.stroke(minor, with: .color(col), lineWidth: 1.4)
    }

    /// 3D applied indices: face, two bevels lit from the upper left
    private static func drawIndices(_ ctx: inout GraphicsContext, dimmed: Bool) {
        for (c, rot, len, w) in FaceGeometry.indices {
            var g = ctx
            g.translateBy(x: c.x, y: c.y); g.rotate(by: .degrees(rot))
            if dimmed { g.opacity = 0.45 }
            let h = len / 2, b = w / 2, bv = min(w * 0.28, 5)
            let body = CGRect(x: -b, y: -h, width: w, height: len)
            if !dimmed { g.fill(Path(body.offsetBy(dx: 2, dy: 3)), with: .color(.black.opacity(0.8))) }
            g.fill(Path(body), with: .color(P.sage))
            func quad(_ pts: [CGPoint], _ col: Color) { var p = Path(); p.addLines(pts); p.closeSubpath(); g.fill(p, with: .color(col)) }
            quad([CGPoint(x: -b, y: -h), CGPoint(x: -b + bv, y: -h + bv), CGPoint(x: -b + bv, y: h - bv), CGPoint(x: -b, y: h)], P.sageLight)
            quad([CGPoint(x: b, y: -h), CGPoint(x: b - bv, y: -h + bv), CGPoint(x: b - bv, y: h - bv), CGPoint(x: b, y: h)], P.sageDark)
            quad([CGPoint(x: -b, y: -h), CGPoint(x: b, y: -h), CGPoint(x: b - bv, y: -h + bv), CGPoint(x: -b + bv, y: -h + bv)], Color(hex: 0xCBD5BE))
            quad([CGPoint(x: -b, y: h), CGPoint(x: b, y: h), CGPoint(x: b - bv, y: h - bv), CGPoint(x: -b + bv, y: h - bv)], Color(hex: 0x46503E))
            g.fill(Path(CGRect(x: -b + bv, y: -h + bv, width: w - 2 * bv, height: len - 2 * bv)), with: .color(Color(hex: 0x97A589)))
        }
    }

    private static func drawNumerals(_ ctx: inout GraphicsContext) {
        for (p, s) in FaceGeometry.numerals {
            ctx.draw(Text(s).font(.custom("PlayfairDisplay-Regular", size: 30)).foregroundColor(P.num), at: p, anchor: .center)
        }
    }

    private static func drawDate(_ ctx: inout GraphicsContext, _ d: Date) {
        let box = CGRect(x: 391, y: 269, width: 180, height: 55)
        ctx.fill(Path(roundedRect: box, cornerRadius: 13), with: .color(Color(hex: 0x0D0E0C)))
        ctx.stroke(Path(roundedRect: box, cornerRadius: 13), with: .color(P.rim), lineWidth: 3.6)
        ctx.stroke(Path(roundedRect: box.insetBy(dx: 4.5, dy: 4.5), cornerRadius: 10), with: .color(.black), lineWidth: 1.6)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "EEE d"
        ctx.draw(Text(f.string(from: d).uppercased()).font(.custom("PlayfairDisplay-Regular", size: 30)).foregroundColor(P.ivory),
                 at: CGPoint(x: box.midX, y: box.midY + 1), anchor: .center)
    }

    // MARK: time

    private static func drawTime(_ ctx: inout GraphicsContext, _ d: Date, dimmed: Bool) {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: d)
        let o = cal.dateComponents([.hour, .minute], from: d.addingTimeInterval(-60))
        let h = c.hour ?? 0, m = c.minute ?? 0, ph = o.hour ?? 0, pm = o.minute ?? 0
        // digits that changed this minute morph during the first 0.75 s, with the escapement overshoot
        let sec = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9
        let t = dimmed ? 1 : GlyphMorph.escape(sec / 0.75)
        let digits: [(Int, Int, GlyphSet, FaceGeometry.Slot?, Color)] = [
            (h / 10, ph / 10, Glyphs.regular, FaceGeometry.hourSlots.first, P.ivory),
            (h % 10, ph % 10, Glyphs.regular, FaceGeometry.hourSlots.last, P.ivory),
            (m / 10, pm / 10, Glyphs.italic, FaceGeometry.minuteSlots.first, P.sage),
            (m % 10, pm % 10, Glyphs.italic, FaceGeometry.minuteSlots.last, P.sage)
        ]
        for (n, prev, set, slot, col) in digits {
            guard let slot, let g = set.digits[n] else { continue }
            let xf = CGAffineTransform(translationX: slot.x, y: slot.base).scaledBy(x: slot.scaleX, y: -slot.scaleY)
            let shape = (t < 1 && prev != n) ? GlyphMorph.path(GlyphMorph.pairs(set, from: prev, to: n), t) : g.path
            let path = shape.applying(xf)
            if !dimmed {   // two offset dark copies stand in for a soft shadow (cheap on the watch GPU)
                ctx.fill(path.applying(CGAffineTransform(translationX: 3, y: 5)), with: .color(.black.opacity(0.35)))
                ctx.fill(path.applying(CGAffineTransform(translationX: 1.5, y: 2.5)), with: .color(.black.opacity(0.45)))
            }
            ctx.fill(path, with: .color(dimmed ? col.opacity(0.7) : col))
        }
    }

    /// seconds runner: a bright tick travels the railway track five beats a second, trailing a fading wake
    private static func drawRunner(_ ctx: inout GraphicsContext, _ d: Date) {
        let c = Calendar.current.dateComponents([.second, .nanosecond], from: d)
        let sec = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9
        let head = Int(sec * 5) % 300, ticks = FaceGeometry.ticks
        for k in 0..<14 {
            let i = (head - k + 300) % 300, (p, n) = ticks[i], len = i % 5 == 0 ? 28.0 : 9.0
            var line = Path(); line.move(to: p); line.addLine(to: CGPoint(x: p.x - n.dx * len, y: p.y - n.dy * len))
            ctx.stroke(line, with: .color(Color(hex: 0xDDEBD2).opacity(0.9 * pow(1 - Double(k) / 14, 1.6))), lineWidth: i % 5 == 0 ? 2.2 : 1.6)
        }
    }

    private static func drawLabel(_ ctx: inout GraphicsContext, _ s: String, dimmed: Bool) {
        guard !s.isEmpty else { return }
        ctx.draw(Text(s).font(.custom("PlayfairDisplay-Regular", size: 27)).kerning(3).foregroundColor(P.text.opacity(dimmed ? 0.6 : 1)),
                 at: CGPoint(x: 484, y: 535), anchor: .center)
    }

    // MARK: subdials

    enum Icon { case shoe, heart }

    /// the subdials are drawn 25% larger than in the original design, so steps and heart rate read at a glance
    static let subdialScale = 1.22

    private static func drawSubdial(_ ctx: inout GraphicsContext, at p: CGPoint, value: String, unit: String?, icon: Icon, progress: Double) {
        var g = ctx
        g.translateBy(x: p.x, y: p.y)
        g.scaleBy(x: subdialScale, y: subdialScale)
        g.translateBy(x: -p.x, y: -p.y)
        drawSubdialUnscaled(&g, at: p, value: value, unit: unit, icon: icon, progress: progress)
    }

    private static func drawSubdialUnscaled(_ ctx: inout GraphicsContext, at p: CGPoint, value: String, unit: String?, icon: Icon, progress: Double) {
        func circle(_ r: Double) -> Path { Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        ctx.fill(circle(81), with: .color(Color(hex: 0x090909)))
        var r = 6.0; while r < 72 { ctx.stroke(circle(r), with: .color(.white.opacity(0.025)), lineWidth: 1); r += 3.2 }
        ctx.stroke(circle(78), with: .color(Color(hex: 0x6F7563)), lineWidth: 6)
        ctx.stroke(circle(77), with: .color(Color(hex: 0xA7AD96)), lineWidth: 2.6)
        ctx.stroke(circle(74.2), with: .color(.black.opacity(0.85)), lineWidth: 1.4)
        // scale: 43 ticks over ±126°, filled ticks show progress
        let lit = Int((min(max(progress, 0), 1) * 42).rounded())
        for j in 0...42 {
            let a = (-126 + Double(j) * 6) * .pi / 180, major = j % 5 == 1 || j == 21
            let r1 = 67.0, r2 = major ? 58.0 : 62.5
            var t = Path()
            t.move(to: CGPoint(x: p.x + sin(a) * r1, y: p.y - cos(a) * r1))
            t.addLine(to: CGPoint(x: p.x + sin(a) * r2, y: p.y - cos(a) * r2))
            let on = j <= lit && progress > 0
            ctx.stroke(t, with: .color(on ? Color(hex: 0xDDD7C7) : Color(hex: 0x6E6C64)), lineWidth: major ? 2.6 : 1.5)
        }
        // icon, small and high, so the number can be large enough to read at a glance
        switch icon {
        case .shoe: ctx.fill(shoePath(in: CGRect(x: p.x - 13.5, y: p.y - 47, width: 27, height: 15.7)), with: .color(P.icon))
        case .heart: ctx.fill(heartPath(in: CGRect(x: p.x - 8.5, y: p.y - 48, width: 17.5, height: 15.7)), with: .color(P.icon))
        }
        let size: CGFloat = value.count <= 3 ? 58 : 46
        ctx.draw(Text(value).font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit()).foregroundColor(P.ivory),
                 at: CGPoint(x: p.x, y: p.y + 6), anchor: .center)
        if let unit {
            ctx.draw(Text(unit).font(.system(size: 15, weight: .medium)).kerning(1.5).foregroundColor(Color(hex: 0xD0CAB9)),
                     at: CGPoint(x: p.x, y: p.y + 44), anchor: .center)
        }
    }

    /// steps short enough for the subdial: 8,431 · 12.2k
    static func compactSteps(_ n: Int) -> String {
        if n < 10_000 { return grouped(n) }
        return String(format: "%.1fk", Double(n) / 1000)
    }

    /// battery level as a whole percentage; nil while watchOS reports no level (monitoring off, simulator)
    static func batteryPercent(_ level: Float) -> Int? {
        guard level >= 0 else { return nil }
        return min(100, max(0, Int((Double(level) * 100).rounded())))
    }

    /// the plaque under the subdials: the watch battery, with a bolt while charging (gold at 20 % and below);
    /// just the bolt where no level is known
    private static func drawPlaque(_ ctx: inout GraphicsContext, battery: Int?, charging: Bool) {
        let width = battery == nil ? 76.5 : 104
        let box = CGRect(x: 484.75 - width / 2, y: 766, width: width, height: 50)
        ctx.fill(Path(roundedRect: box, cornerRadius: 11), with: .color(Color(hex: 0x0D0E0C)))
        ctx.stroke(Path(roundedRect: box, cornerRadius: 11), with: .color(P.rim), lineWidth: 3.6)
        if let battery {
            let colour = battery <= 20 && !charging ? P.gold : P.ivory
            var text = Text("\(battery)%").font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()).foregroundColor(colour)
            if charging {
                text = Text(Image(systemName: "bolt.fill")).font(.system(size: 18, weight: .semibold)).foregroundColor(P.sageLight) + Text(" ") + text
            }
            ctx.draw(text, at: CGPoint(x: box.midX, y: box.midY + 1), anchor: .center)
            return
        }
        var bolt = Path()
        let s = 30 / 13.2, c = CGPoint(x: 484.5, y: 791)
        bolt.addLines([(1, -6.6), (-3.8, 0.9), (-0.5, 0.9), (-1.3, 6.6), (3.8, -1), (0.5, -1)].map { CGPoint(x: c.x + $0.0 * s, y: c.y + $0.1 * s) })
        bolt.closeSubpath()
        ctx.fill(bolt, with: .color(Color(hex: 0xC0B89E)))
    }

    // MARK: icon shapes (12 x 6.6 and 10 x 9 design boxes, as in the prototype)

    static func shoePath(in r: CGRect) -> Path {
        let sx = r.width / 12, sy = r.height / 6.6
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var a = Path()
        a.move(to: p(0.3, 4.6))
        a.addCurve(to: p(1.1, 2.7), control1: p(0.1, 3.6), control2: p(0.4, 3))
        a.addCurve(to: p(3.4, 1.2), control1: p(2, 2.4), control2: p(2.7, 2.2))
        a.addCurve(to: p(4.9, 0.4), control1: p(3.8, 0.6), control2: p(4.3, 0.3))
        a.addLine(to: p(6.1, 0.7))
        a.addCurve(to: p(8.5, 2.4), control1: p(6.5, 1.5), control2: p(7.3, 2.1))
        a.addCurve(to: p(11.9, 4.6), control1: p(10.4, 2.9), control2: p(11.8, 3.6))
        a.closeSubpath()
        a.move(to: p(0.2, 5.2)); a.addLine(to: p(11.9, 5.2))
        a.addCurve(to: p(10.6, 6.5), control1: p(11.9, 6), control2: p(11.4, 6.5))
        a.addLine(to: p(1.1, 6.5))
        a.addCurve(to: p(0.2, 5.2), control1: p(0.5, 6.5), control2: p(0.2, 6))
        a.closeSubpath()
        return a
    }

    static func heartPath(in r: CGRect) -> Path {
        let sx = r.width / 10, sy = r.height / 9
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var h = Path()
        h.move(to: p(5, 9))
        h.addCurve(to: p(0, 2.7), control1: p(1, 6), control2: p(0, 4.3))
        h.addCurve(to: p(2.6, 0), control1: p(0, 1.2), control2: p(1.2, 0))
        h.addCurve(to: p(5, 1.5), control1: p(3.7, 0), control2: p(4.5, 0.6))
        h.addCurve(to: p(7.4, 0), control1: p(5.5, 0.6), control2: p(6.3, 0))
        h.addCurve(to: p(10, 2.7), control1: p(8.8, 0), control2: p(10, 1.2))
        h.addCurve(to: p(5, 9), control1: p(10, 4.3), control2: p(9, 6))
        h.closeSubpath()
        return h
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
