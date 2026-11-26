import SwiftUI

/// Everything the face shows at one instant.
struct FaceState {
    var date: Date
    var mode: FaceMode
    var music: Bool = false           // something plays on the iPhone: a small equalizer under the time
    var dimmed: Bool = false          // always-on (luminance reduced)
    var battery: Int? = nil           // watch battery in percent; nil where unknown (the plaque then shows only the bolt)
    var charging: Bool = false

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
        drawTime(&ctx, state.date, dimmed: state.dimmed)
        if !state.dimmed && state.music { drawMusic(&ctx, state.date) }
        if !state.dimmed && state.mode != .sleeping {
            drawPlaque(&ctx, battery: state.battery, charging: state.charging, date: state.date, dimmed: false)
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
        // a long, bright wake so the seconds read at a glance: the head is ivory and wide, the trail fades over 6 s
        let trail = 30
        for k in 0..<trail {
            let i = (head - k + 300) % 300, (p, n) = ticks[i], len = i % 5 == 0 ? 32.0 : 18.0
            var line = Path(); line.move(to: p); line.addLine(to: CGPoint(x: p.x - n.dx * len, y: p.y - n.dy * len))
            let fade = pow(1 - Double(k) / Double(trail), 1.3)
            ctx.stroke(line, with: .color(Color(hex: k == 0 ? 0xFFFFFF : 0xDDEBD2).opacity(fade)), lineWidth: k == 0 ? 5 : (i % 5 == 0 ? 3.6 : 3))
        }
    }



    /// battery level as a whole percentage; nil while watchOS reports no level (monitoring off, simulator)
    static func batteryPercent(_ level: Float) -> Int? {
        guard level >= 0 else { return nil }
        return min(100, max(0, Int((Double(level) * 100).rounded())))
    }

    /// the plaque at the bottom: the watch battery, with a bolt while charging (gold at 20 % and below);
    /// just the bolt where no level is known
    /// the music indicator's place in the reference space (also the tap area on the watch)
    static let musicRect = CGRect(x: 479 - 45, y: 730, width: 90, height: 50)

    /// maps a rectangle of the reference space to view coordinates for a face drawn into `size`
    static func viewRect(_ r: CGRect, in size: CGSize) -> CGRect {
        let src = FaceGeometry.screen
        let scale = max(size.width / src.width, size.height / src.height)
        let ox = (size.width - src.width * scale) / 2 - src.minX * scale, oy = (size.height - src.height * scale) / 2 - src.minY * scale
        return CGRect(x: ox + r.minX * scale, y: oy + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    /// four rounded bars bouncing gently, centred just above the battery bar
    private static func drawMusic(_ ctx: inout GraphicsContext, _ d: Date) {
        let t = d.timeIntervalSinceReferenceDate
        let r = musicRect, w = 8.0, gap = 7.0, maxH = 34.0, minH = 8.0
        let x0 = r.midX - (4 * w + 3 * gap) / 2, base = r.midY + maxH / 2
        let speeds = [2.1, 2.9, 2.4, 3.3], offsets = [0.0, 1.3, 2.6, 0.7]
        for i in 0..<4 {
            let v = 0.5 + 0.5 * sin(t * speeds[i] * 2 + offsets[i])
            let h = minH + (maxH - minH) * v
            let bar = CGRect(x: x0 + Double(i) * (w + gap), y: base - h, width: w, height: h)
            ctx.fill(Path(roundedRect: bar, cornerRadius: w / 2), with: .color(P.sageLight))
        }
    }

    /// the level the bar shows; it eases toward the real level so changes slide instead of jumping
    private static var shownLevel: Double?

    /// battery colours: ivory, yellow at 20 % and below, red at 10 % and below, green while charging
    static func batteryColour(_ percent: Int, charging: Bool) -> Color {
        if charging { return P.sageLight }
        if percent <= 10 { return Color(hex: 0xD9503F) }
        if percent <= 20 { return Color(hex: 0xE3B341) }
        return P.ivory
    }

    /// the watch battery as a thin bar at the bottom; the fill eases to the level so changes slide
    private static func drawPlaque(_ ctx: inout GraphicsContext, battery: Int?, charging: Bool, date: Date, dimmed: Bool) {
        guard let battery else { return }
        let target = Double(battery) / 100
        var level = shownLevel ?? target
        level += (target - level) * 0.08
        if abs(level - target) < 0.002 { level = target }
        shownLevel = level
        let track = CGRect(x: 479 - 70, y: 796, width: 140, height: 13)
        ctx.fill(Path(roundedRect: track, cornerRadius: 6.5), with: .color(P.track))
        ctx.fill(Path(roundedRect: CGRect(x: track.minX, y: track.minY, width: max(13, track.width * level), height: track.height), cornerRadius: 6.5),
                 with: .color(batteryColour(battery, charging: charging)))
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
