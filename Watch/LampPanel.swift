import SwiftUI
import WatchKit
import WatchConnectivity

/// The watch side of lamp control. The watch cannot reach the bulbs itself, so it asks the iPhone; "at home" means
/// the iPhone answered and at least one bulb replied on the local network.
@MainActor
final class LampModel: ObservableObject {
    static let shared = LampModel()

    @Published private(set) var state = LampLink.State()
    @Published private(set) var busy = false
    /// why the lamps are not available, in plain words (nil while at home)
    @Published private(set) var problem: String? = "Checking…"
    var home: Bool { state.home }

    private var lastCheck = Date.distantPast
    private var pending: [String: Any]?
    private var sending = false
    private var lastLocalChange = Date.distantPast

    /// ask the iPhone for the lamp state (at most every 20 s unless forced)
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheck) > 20 else { return }
        lastCheck = Date()
        send([LampLink.commandKey: LampLink.status])
    }

    /// change the lamps; rapid changes (crown, slider) are coalesced so only the latest goes out
    func set(_ params: [String: Any]) {
        lastLocalChange = Date()
        apply(params)
        pending = params
        flush()
    }

    func toggle() { set(["state": !state.on]) }
    /// one slider for everything, like Control Center: 0 is off, anything above sets the brightness (10...100 %)
    func setLevel(_ level: Double) {
        if level < 0.02 { if state.on { set(["state": false]) }; return }
        let pct = min(100, max(10, Int((level * 100).rounded())))
        if !state.on || pct != state.dimming { set(["state": true, "dimming": pct]) }
    }
    func brightness(_ v: Int) { set(["state": true, "dimming": min(100, max(10, v))]) }
    func temperature(_ k: Int) { set(["state": true, "temp": k, "dimming": state.dimming]) }
    func colour(_ c: (Int, Int, Int)) { set(["state": true, "r": c.0, "g": c.1, "b": c.2, "dimming": state.dimming]) }

    /// optimistic update so the panel reacts at once
    private func apply(_ p: [String: Any]) {
        if let on = p["state"] as? Bool { state.on = on }
        if let d = p["dimming"] as? Int { state.dimming = d }
        if let t = p["temp"] as? Int { state.temp = t; state.rgb = nil }
        if let r = p["r"] as? Int, let g = p["g"] as? Int, let b = p["b"] as? Int { state.rgb = (r, g, b); state.temp = nil }
    }

    private func flush() {
        guard !sending, let p = pending else { return }
        pending = nil
        sending = true
        send([LampLink.commandKey: LampLink.set, LampLink.paramsKey: p]) { [weak self] in
            self?.sending = false
            self?.flush()
        }
    }

    private func send(_ message: [String: Any], done: (() -> Void)? = nil) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            state.home = false
            problem = "iPhone not reachable. Keep it nearby with Bluetooth on."
            done?(); return
        }
        busy = true
        session.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in
                let s = LampLink.State(reply)
                // keep what the user just set: replies (and the bulbs' own reports) lag behind the slider, and taking
                // them over would make it jump back after release
                if self.pending == nil && Date().timeIntervalSince(self.lastLocalChange) > 2.5 { self.state = s }
                else { self.state.home = s.home; self.state.count = s.count }
                self.problem = s.home ? nil : "No lamp answered. Open Sage on the iPhone once and allow Local Network, then retry."
                self.busy = false
                done?()
            }
        }, errorHandler: { _ in
            Task { @MainActor in
                self.state.home = false; self.busy = false
                self.problem = "The iPhone did not answer. Open Sage on the iPhone and retry."
                done?()
            }
        })
    }
}

/// The lamp, Control Center style: one capsule is power and brightness together.
///  - tap: on / off (the fill rises to the last brightness or drops away)
///  - press and slide: brightness, relative to where the finger lands; all the way down is off.
///    The capsule lifts slightly while held, stretches with growing resistance past either end and springs back.
///  - long press: the capsule zooms into a honeycomb of colours, laid out like the watch's app grid
///  - Digital Crown: the same brightness, with the system's detents
/// The percentage shows only while it changes.
struct LampPanel: View {
    @ObservedObject var lamp: LampModel
    @Environment(\.dismiss) private var dismiss

    @State private var dragLevel: Double?
    @State private var dragStart: Double = 0
    @State private var touching = false
    @State private var moved = false
    @State private var longFired = false
    @State private var lifted = false
    @State private var overshoot: CGFloat = 0        // rubber band: + past the top, - past the bottom
    @State private var lastEdge = -1
    @State private var colours = false
    @State private var appeared = false
    @State private var crown: Double = 0
    @State private var crownSync = false
    @State private var showValue = false
    @State private var pressTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    static func tint(_ s: LampLink.State) -> Color {
        if let c = s.rgb { return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255) }
        return kelvin(s.temp ?? 2700)
    }

    /// approximate colour of a white at `k` kelvin, as the eye sees the bulb
    static func kelvin(_ k: Int) -> Color {
        let t = min(1, max(0, Double(k - 2200) / Double(6500 - 2200)))
        return Color(red: 1, green: 0.66 + 0.30 * t, blue: 0.36 + 0.62 * t)
    }

    /// Apple's rubber band: the further past the end, the less it moves; never more than `limit`
    static func rubber(_ x: CGFloat, limit d: CGFloat) -> CGFloat {
        guard x != 0 else { return 0 }
        let v = (1 - 1 / (abs(x) * 0.55 / d + 1)) * d
        return x > 0 ? v : -v
    }

    private var modelLevel: Double { lamp.state.on ? Double(lamp.state.dimming) / 100 : 0 }
    private var level: Double { appeared ? (dragLevel ?? modelLevel) : 0 }

    var body: some View {
        Group {
            if lamp.home { content } else { unavailable }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
            }
        }
    }

    /// not at home, or the iPhone could not reach the lamps: say why, offer a retry
    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "lightbulb.slash").font(.system(size: 26)).foregroundStyle(FaceGeometry.Palette.sage)
            Text(lamp.busy ? "Checking…" : (lamp.problem ?? "Checking…"))
                .font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(FaceGeometry.Palette.ivory)
            Button("Retry") { lamp.refresh(force: true) }.disabled(lamp.busy)
        }
        .onAppear { lamp.refresh(force: true) }
    }

    private var content: some View {
        GeometryReader { geo in
            let h = min(geo.size.height - 34, 150.0), w = (h * 0.5).rounded()
            ZStack {
                capsule(width: w, height: h)
                    .scaleEffect(colours ? 0.5 : 1)
                    .opacity(colours ? 0 : 1)
                    .blur(radius: colours ? 6 : 0)
                    .allowsHitTesting(!colours)
                Text(level > 0 ? "\(Int((level * 100).rounded()))%" : "Off")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: level))
                    .offset(y: -h / 2 - 16)
                    .opacity(showValue && !colours ? 1 : 0)
                if colours {
                    Honeycomb(state: lamp.state, size: geo.size, pick: choose, cancel: closeColours)
                        .transition(.asymmetric(insertion: .scale(scale: 0.45).combined(with: .opacity),
                                                removal: .scale(scale: 1.2).combined(with: .opacity)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .focusable()
        .focusEffectDisabled()
        .digitalCrownRotation($crown, from: 0, through: 100, by: 1, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, v in
            if crownSync { crownSync = false; return }
            if colours || touching { syncCrown(); return }
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) { lamp.setLevel(v / 100) }
            reveal(holding: false)
        }
        .onChange(of: modelLevel) { _, _ in syncCrown() }
        .onAppear {
            syncCrown()
            lamp.refresh(force: true)
            // the fill rises into place as the panel opens
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82).delay(0.12)) { appeared = true }
        }
    }

    private func capsule(width w: CGFloat, height h: CGFloat) -> some View {
        let stretch = abs(overshoot)
        let fullH = h + stretch, fullW = w * (1 - min(stretch / h, 0.15) * 0.5)
        let shape = RoundedRectangle(cornerRadius: w * 0.4, style: .continuous)
        return ZStack(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.18))
            Rectangle().fill(Self.tint(lamp.state)).frame(height: fullH * level)
            Image(systemName: level > 0 ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: w * 0.3, weight: .medium))
                .foregroundStyle(level > 0.12 ? Color.black.opacity(0.55) : Color.white.opacity(0.8))
                .contentTransition(.symbolEffect(.replace))
                .padding(.bottom, w * 0.3)
        }
        .frame(width: fullW, height: fullH)
        .clipShape(shape)
        .offset(y: overshoot > 0 ? -stretch / 2 : stretch / 2)      // stretch away from the fixed end
        .scaleEffect(lifted ? 1.06 : 1)
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { touch($0, height: h) }
            .onEnded { _ in release() })
        .accessibilityElement()
        .accessibilityLabel(Text("Lamps"))
        .accessibilityValue(Text(level > 0 ? "\(Int((level * 100).rounded())) percent" : "Off"))
        .accessibilityAdjustableAction { dir in lamp.setLevel(min(1, max(0, modelLevel + (dir == .increment ? 0.1 : -0.1)))) }
        .accessibilityAction { lamp.toggle() }
        .accessibilityAction(named: Text("Colours")) { withAnimation { colours = true } }
    }

    private func touch(_ g: DragGesture.Value, height h: CGFloat) {
        if !touching {
            touching = true; moved = false; longFired = false
            dragStart = modelLevel
            lastEdge = dragStart <= 0 ? 0 : dragStart >= 1 ? 1 : -1
            pressTask?.cancel()
            pressTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled, touching, !moved else { return }
                longFired = true
                WKInterfaceDevice.current().play(.click)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { colours = true }
            }
        }
        guard !longFired else { return }
        if !moved {
            guard abs(g.translation.height) > 5 || abs(g.translation.width) > 5 else { return }
            moved = true
            pressTask?.cancel()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { lifted = true }
            reveal(holding: true)
        }
        let raw = dragStart - Double(g.translation.height / h)
        let clamped = min(1, max(0, raw))
        overshoot = Self.rubber(CGFloat(raw - clamped) * h, limit: h * 0.22)
        let edge = clamped <= 0 ? 0 : clamped >= 1 ? 1 : -1
        if edge != -1 && edge != lastEdge { WKInterfaceDevice.current().play(.click) }
        lastEdge = edge
        dragLevel = clamped
        lamp.setLevel(clamped)
    }

    private func release() {
        pressTask?.cancel()
        defer { touching = false }
        guard !longFired else { return }
        if !moved {
            WKInterfaceDevice.current().play(.click)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { lamp.toggle() }
            return
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { overshoot = 0 }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { lifted = false; dragLevel = nil }
        reveal(holding: false)
    }

    /// the percentage fades in while the level changes and out shortly after
    private func reveal(holding: Bool) {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { showValue = true }
        guard !holding else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { showValue = false }
        }
    }

    private func syncCrown() {
        let target = modelLevel * 100
        if abs(target - crown) > 0.5 { crownSync = true; crown = target }
    }

    private func choose(_ s: Swatch) {
        WKInterfaceDevice.current().play(.click)
        withAnimation(.easeInOut(duration: 0.35)) {
            switch s {
            case .white(let k): lamp.temperature(k)
            case .colour(let r, let g, let b): lamp.colour((r, g, b))
            }
        }
        closeColours()
    }

    private func closeColours() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { colours = false }
    }
}

/// One colour choice.
enum Swatch: Hashable {
    case white(Int)
    case colour(Int, Int, Int)

    var color: Color {
        switch self {
        case .white(let k): return LampPanel.kelvin(k)
        case .colour(let r, let g, let b): return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }

    var name: String {
        switch self {
        case .white(let k): return "White \(k) kelvin"
        case .colour: return "Colour"
        }
    }

    func matches(_ s: LampLink.State) -> Bool {
        switch self {
        case .white(let k): return s.rgb == nil && s.temp == k
        case .colour(let r, let g, let b):
            guard let c = s.rgb else { return false }
            return abs(c.0 - r) + abs(c.1 - g) + abs(c.2 - b) < 12
        }
    }
}

/// Colours laid out like the Apple Watch app grid: a honeycomb of bubbles you can pan, shrinking toward the screen
/// edges. Whites in the middle (warm to cool around the centre), twelve hues in the outer ring, in colour-wheel order.
/// It blooms out ring by ring; tapping empty space goes back to the slider.
struct Honeycomb: View {
    let state: LampLink.State
    let size: CGSize
    let pick: (Swatch) -> Void
    let cancel: () -> Void

    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var bloomed = false

    static let diameter: CGFloat = 42
    static let pitch: CGFloat = 47

    struct Cell: Identifiable {
        let id: Int
        let pos: CGPoint
        let ring: Int
        let swatch: Swatch
    }

    static let cells: [Cell] = {
        var raw: [(p: CGPoint, ring: Int, angle: Double)] = []
        for q in -2...2 {
            for r in -2...2 where abs(q + r) <= 2 {
                let x = pitch * (CGFloat(q) + CGFloat(r) / 2), y = pitch * CGFloat(r) * sqrt(3) / 2
                var a = atan2(Double(x), Double(-y))            // 0 at the top, clockwise
                if a < 0 { a += 2 * .pi }
                raw.append((CGPoint(x: x, y: y), max(abs(q), abs(r), abs(q + r)), a))
            }
        }
        let whites = [2200, 3000, 3500, 4200, 5200, 6500]
        var out: [Cell] = [], i = 0
        for c in raw.sorted(by: { ($0.ring, $0.angle) < ($1.ring, $1.angle) }) {
            let s: Swatch
            switch c.ring {
            case 0: s = .white(2700)
            case 1: s = .white(whites[i]); i += 1
            default:
                let rgb = hue(c.angle / (2 * .pi))
                s = .colour(rgb.0, rgb.1, rgb.2)
            }
            out.append(Cell(id: out.count, pos: c.p, ring: c.ring, swatch: s))
        }
        return out
    }()

    static func hue(_ h: Double) -> (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(hue: h, saturation: 1, brightness: 1, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { cancel() }
            ForEach(Self.cells) { bubble($0) }
        }
        .frame(width: size.width, height: size.height)
        .simultaneousGesture(DragGesture(minimumDistance: 6)
            .onChanged { g in
                pan = CGSize(width: bound(panBase.width + g.translation.width, Self.panLimit.width),
                             height: bound(panBase.height + g.translation.height, Self.panLimit.height))
            }
            .onEnded { _ in
                let l = Self.panLimit
                panBase = CGSize(width: min(l.width, max(-l.width, pan.width)), height: min(l.height, max(-l.height, pan.height)))
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { pan = panBase }
            })
        .onAppear {
            // open centred on the colour that is set, as the app grid opens on the last app
            if let cur = Self.cells.first(where: { $0.swatch.matches(state) }) {
                panBase = CGSize(width: -cur.pos.x, height: -cur.pos.y)
                pan = panBase
            }
            bloomed = true
        }
    }

    /// far enough that any bubble, the outer ring included, can be brought to the full-size middle
    static let panLimit = CGSize(width: 2 * pitch, height: 2 * pitch * sqrt(3) / 2)

    /// free inside the limit, rubber band beyond it
    private func bound(_ v: CGFloat, _ lim: CGFloat) -> CGFloat {
        guard abs(v) > lim else { return v }
        let extra = LampPanel.rubber(abs(v) - lim, limit: 28)
        return v > 0 ? lim + extra : -lim - extra
    }

    private func bubble(_ cell: Cell) -> some View {
        let f = fisheye(CGPoint(x: cell.pos.x + pan.width, y: cell.pos.y + pan.height))
        let selected = cell.swatch.matches(state)
        return Button { pick(cell.swatch) } label: {
            Circle().fill(cell.swatch.color)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: selected ? 3 : 0))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: selected ? 1 : 0).padding(3))
        }
        .buttonStyle(.plain)
        .frame(width: Self.diameter, height: Self.diameter)
        .scaleEffect(bloomed ? f.scale : 0.15)
        .opacity(bloomed ? 1 : 0)
        .position(x: size.width / 2 + (bloomed ? f.point.x : 0), y: size.height / 2 + (bloomed ? f.point.y : 0))
        .animation(.spring(response: 0.5, dampingFraction: 0.74).delay(Double(cell.ring) * 0.05), value: bloomed)
        .accessibilityLabel(Text(cell.swatch.name))
    }

    /// Bubble UI model of the app grid: a centre zone where bubbles are full size, and a fringe around it in which
    /// they ease down to a minimum size while sliding inward, so the edge stays packed instead of clipping.
    private func fisheye(_ p: CGPoint) -> (point: CGPoint, scale: CGFloat) {
        let d = Self.diameter
        let hx = size.width / 2 - d * 0.75, hy = size.height / 2 - d * 0.75      // centre zone (half extents)
        let fringe = d * 1.1
        let ex = max(0, abs(p.x) - hx), ey = max(0, abs(p.y) - hy)
        let t = min(1, hypot(ex, ey) / fringe)
        guard t > 0 else { return (p, 1) }
        let e = t * t * (3 - 2 * t)                                               // smoothstep
        let len = max(hypot(p.x, p.y), 1), pull = e * d * 0.5
        return (CGPoint(x: p.x - p.x / len * pull, y: p.y - p.y / len * pull), 1 - 0.62 * e)
    }
}
