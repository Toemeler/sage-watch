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

    /// ask the iPhone for the lamp state (at most every 20 s unless forced)
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheck) > 20 else { return }
        lastCheck = Date()
        send([LampLink.commandKey: LampLink.status])
    }

    /// change the lamps; rapid changes (crown, slider) are coalesced so only the latest goes out
    func set(_ params: [String: Any]) {
        apply(params)
        pending = params
        flush()
    }

    func toggle() { set(["state": !state.on]) }
    /// one slider for everything, like Control Center: 0 is off, anything above sets the brightness (10...100 %)
    func setLevel(_ level: Double) {
        if level < 0.04 { if state.on { set(["state": false]) }; return }
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
                // keep the optimistic values while more changes are queued
                if self.pending == nil { self.state = s } else { self.state.home = s.home }
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

/// The lamp, Control Center style: one tall slider is power and brightness together.
/// Tap: on / off. Press and slide up or down: brightness (down to the bottom turns it off). Long press: colours.
/// The Digital Crown moves the same slider, with detents and the fill following it.
/// While touched the slider grows toward the finger; dragged past either end it stretches (rubber band) and
/// springs back on release.
struct LampPanel: View {
    @ObservedObject var lamp: LampModel
    @State private var live: Double?                 // level while the finger or crown moves it
    @State private var start: (level: Double, moved: Bool)?
    @State private var longFired = false
    @State private var pressed = false
    @State private var stretch: CGFloat = 0          // rubber band: + past the top, - past the bottom
    @State private var showColours = false
    @State private var crown: Double = 0
    @State private var crownFromLamp = false
    @State private var pressTask: Task<Void, Never>?

    static func tint(_ s: LampLink.State) -> Color {
        if let c = s.rgb { return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255) }
        return kelvin(s.temp ?? 2700)
    }

    static func kelvin(_ k: Int) -> Color {
        let t = Double(k - 2200) / Double(6500 - 2200)
        return Color(red: 1, green: 0.62 + 0.33 * t, blue: 0.28 + 0.72 * t)
    }

    private var level: Double { live ?? (lamp.state.on ? Double(lamp.state.dimming) / 100 : 0) }

    var body: some View {
        if lamp.home { slider } else { unavailable }
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
        .navigationTitle("Lamp")
    }

    private var slider: some View {
        GeometryReader { geo in
            let h = min(geo.size.height - 24, 160.0), w = min(92.0, h * 0.58)
            VStack(spacing: 6) {
                pill(width: w, height: h)
                Text(level > 0 ? "\(Int((level * 100).rounded())) %" : "Off")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(FaceGeometry.Palette.ivory.opacity(0.8))
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusable()
        .digitalCrownRotation($crown, from: 0, through: 100, by: 5, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, v in
            if crownFromLamp { crownFromLamp = false; return }
            withAnimation(.easeOut(duration: 0.12)) { live = v / 100 }
            lamp.setLevel(v / 100)
        }
        .onChange(of: lamp.state.on) { _, _ in syncCrown() }
        .onChange(of: lamp.state.dimming) { _, _ in syncCrown() }
        .onAppear { syncCrown(); lamp.refresh(force: true) }
        .sheet(isPresented: $showColours) { ColourSheet(lamp: lamp) }
        .navigationTitle("Lamp")
    }

    private func syncCrown() {
        guard start == nil else { return }
        live = nil
        let target = lamp.state.on ? Double(lamp.state.dimming) : 0
        if abs(target - crown) > 0.5 { crownFromLamp = true; crown = target }
    }

    private func pill(width w: CGFloat, height h: CGFloat) -> some View {
        let tint = Self.tint(lamp.state)
        let radius = w * 0.42
        // stretch: the pill gets longer toward the overshoot and a little narrower, anchored on the opposite end
        let sy = 1 + abs(stretch) / h, sx = 1 - min(abs(stretch) / h, 0.12) * 0.6
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.16))
            Rectangle().fill(tint).frame(height: h * level)
            Image(systemName: level > 0 ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: w * 0.26, weight: .semibold))
                .foregroundStyle(level > 0.14 ? Color.black.opacity(0.7) : FaceGeometry.Palette.ivory)
                .padding(.bottom, h * 0.07)
                .symbolEffect(.bounce, value: lamp.state.on)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .scaleEffect(x: sx, y: sy, anchor: stretch > 0 ? .bottom : .top)
        .scaleEffect(pressed ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressed)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in touch(g, height: h) }.onEnded { _ in release() })
        .accessibilityElement()
        .accessibilityLabel(Text("Lamp"))
        .accessibilityValue(Text(level > 0 ? "\(Int(level * 100)) percent" : "off"))
        .accessibilityAdjustableAction { dir in lamp.setLevel(min(1, max(0, level + (dir == .increment ? 0.1 : -0.1)))) }
        .accessibilityAction { lamp.toggle() }
    }

    private func touch(_ g: DragGesture.Value, height h: CGFloat) {
        if start == nil {
            start = (level, false); longFired = false; pressed = true
            pressTask?.cancel()
            pressTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let s = start, !s.moved else { return }
                longFired = true; pressed = false
                WKInterfaceDevice.current().play(.click)
                showColours = true
            }
        }
        guard var s = start, !longFired else { return }
        let dy = g.translation.height
        if !s.moved && abs(dy) > 6 { s.moved = true; start = s; pressTask?.cancel() }
        guard s.moved else { return }
        let raw = s.level - Double(dy / h)
        let clamped = min(1, max(0, raw))
        // past the ends the pill resists like a rubber band
        let over = (raw - clamped) * Double(h)
        stretch = over == 0 ? 0 : CGFloat((over > 0 ? 1 : -1) * sqrt(abs(over)) * 2.2)
        if (clamped == 0 || clamped == 1) && clamped != live { WKInterfaceDevice.current().play(.click) }
        live = clamped
        lamp.setLevel(clamped)
    }

    private func release() {
        pressTask?.cancel()
        defer { start = nil; pressed = false }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { stretch = 0 }
        guard let s = start, !longFired else { return }
        if !s.moved {
            WKInterfaceDevice.current().play(.click)
            lamp.toggle()
        }
        live = nil
    }
}

/// Long press: whites and colours. Tap one to set it; the sheet closes.
struct ColourSheet: View {
    @ObservedObject var lamp: LampModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("White").font(.system(size: 12, weight: .semibold)).foregroundStyle(FaceGeometry.Palette.sage)
                grid(LampLink.temps.map { LampPanel.kelvin($0) }, selected: LampLink.temps.firstIndex { $0 == lamp.state.temp }) {
                    lamp.temperature(LampLink.temps[$0])
                }
                Text("Colour").font(.system(size: 12, weight: .semibold)).foregroundStyle(FaceGeometry.Palette.sage)
                grid(LampLink.colours.map { Color(red: Double($0.0) / 255, green: Double($0.1) / 255, blue: Double($0.2) / 255) },
                     selected: LampLink.colours.firstIndex { c in lamp.state.rgb.map { $0 == c } ?? false }) {
                    lamp.colour(LampLink.colours[$0])
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func grid(_ colours: [Color], selected: Int?, tap: @escaping (Int) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(colours.indices, id: \.self) { i in
                Button {
                    WKInterfaceDevice.current().play(.click)
                    tap(i)
                    dismiss()
                } label: {
                    Circle().fill(colours[i])
                        .frame(height: 40)
                        .overlay(Circle().stroke(Color.white, lineWidth: selected == i ? 3 : 0))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
