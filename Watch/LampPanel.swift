import SwiftUI
import WatchConnectivity

/// The watch side of lamp control. The watch cannot reach the bulbs itself, so it asks the iPhone; "at home" means
/// the iPhone answered and at least one bulb replied on the local network.
@MainActor
final class LampModel: ObservableObject {
    static let shared = LampModel()

    @Published private(set) var state = LampLink.State()
    @Published private(set) var busy = false
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
            state.home = false; done?(); return
        }
        busy = true
        session.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in
                let s = LampLink.State(reply)
                // keep the optimistic values while more changes are queued
                if self.pending == nil { self.state = s } else { self.state.home = s.home }
                self.busy = false
                done?()
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.state.home = false; self.busy = false; done?() }
        })
    }
}

/// Small lamp button shown on the face while at home.
struct LampButton: View {
    @ObservedObject var lamp: LampModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: lamp.state.on ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(lamp.state.on ? LampPanel.tint(lamp.state) : FaceGeometry.Palette.sage)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(hex: 0x0D0E0C)))
                .overlay(Circle().stroke(FaceGeometry.Palette.rim, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Lamp"))
    }
}

/// Control Center style panel: a big power button, brightness on a tall slider (and the Digital Crown),
/// white temperatures and colours as swatches.
struct LampPanel: View {
    @ObservedObject var lamp: LampModel
    @State private var crown: Double = 100
    @State private var crownReady = false

    static func tint(_ s: LampLink.State) -> Color {
        if let c = s.rgb { return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255) }
        return kelvin(s.temp ?? 2700)
    }

    static func kelvin(_ k: Int) -> Color {
        let t = Double(k - 2200) / Double(6500 - 2200)
        return Color(red: 1, green: 0.62 + 0.33 * t, blue: 0.28 + 0.72 * t)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: lamp.toggle) {
                        VStack(spacing: 4) {
                            Image(systemName: lamp.state.on ? "lightbulb.fill" : "lightbulb")
                                .font(.system(size: 26, weight: .semibold))
                            Text(lamp.state.on ? "On" : "Off").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(lamp.state.on ? Color.black : FaceGeometry.Palette.ivory)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 18).fill(lamp.state.on ? Self.tint(lamp.state) : Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)

                    brightnessBar
                }
                .frame(height: 110)

                swatches(LampLink.temps.map { Self.kelvin($0) }, selected: LampLink.temps.firstIndex { $0 == lamp.state.temp }) { i in
                    lamp.temperature(LampLink.temps[i])
                }
                swatches(LampLink.colours.map { Color(red: Double($0.0) / 255, green: Double($0.1) / 255, blue: Double($0.2) / 255) },
                         selected: LampLink.colours.firstIndex { c in lamp.state.rgb.map { $0 == c } ?? false }) { i in
                    lamp.colour(LampLink.colours[i])
                }

                if lamp.state.count > 0 {
                    Text("\(lamp.state.count) lamp\(lamp.state.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(FaceGeometry.Palette.sage)
                }
            }
            .padding(.horizontal, 4)
        }
        .focusable()
        .digitalCrownRotation($crown, from: 10, through: 100, by: 5, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, v in if crownReady { lamp.brightness(Int(v)) } }
        .onAppear {
            crown = Double(lamp.state.dimming)
            lamp.refresh(force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { crownReady = true }
        }
        .navigationTitle("Lamp")
    }

    /// tall slider: drag up and down, the fill shows the brightness
    private var brightnessBar: some View {
        GeometryReader { geo in
            let level = Double(lamp.state.dimming) / 100
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 18).fill(Color.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 18).fill(lamp.state.on ? Self.tint(lamp.state) : Color.white.opacity(0.25))
                    .frame(height: geo.size.height * level)
                Image(systemName: "sun.max.fill").font(.system(size: 16)).foregroundStyle(Color.black.opacity(0.6)).padding(.bottom, 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let v = 1 - g.location.y / geo.size.height
                let pct = Int((min(max(v, 0.1), 1) * 100 / 5).rounded()) * 5
                if pct != lamp.state.dimming || !lamp.state.on { lamp.brightness(pct); crownReady = false; crown = Double(pct); crownReady = true }
            })
        }
        .frame(width: 58)
    }

    private func swatches(_ colours: [Color], selected: Int?, tap: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(colours.indices, id: \.self) { i in
                Button { tap(i) } label: {
                    Circle().fill(colours[i])
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.white, lineWidth: selected == i ? 2.5 : 0))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
