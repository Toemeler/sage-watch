import SwiftUI
import WatchKit
import WatchConnectivity

/// The watch side of lamp control. The watch cannot reach the bulbs itself (watchOS allows no UDP for regular apps),
/// so it asks the iPhone; "at home" means the iPhone answered and at least one bulb replied on the local network.
///
/// Made to feel instant: the last good state is kept on the watch, so the panel opens with it at once when the lamps
/// answered within the last 15 minutes, and is corrected when the fresh answer arrives. Messages wait up to 3 s for
/// the iPhone to become reachable and are retried twice before anything is reported as failed.
@MainActor
final class LampModel: ObservableObject {
    static let shared = LampModel()

    @Published private(set) var state = LampLink.State()
    /// a message to the iPhone is out (a counter underneath: a status check and a change can overlap, and the
    /// first to finish must not clear it for the other)
    @Published private(set) var busy = false
    private var inFlight = 0 { didSet { busy = inFlight > 0 } }
    /// why the lamps are not available, in plain words (nil while at home)
    @Published private(set) var problem: String? = "Checking…"
    /// when a change last failed to reach the lamps (the panel flashes a note and plays the failure haptic)
    @Published private(set) var failedAt: Date?
    var home: Bool { state.home }
    /// the last state the lamps confirmed; a change that never arrives falls back to it
    private var confirmed: LampLink.State?
    /// when the lamp last answered (the panel keeps its controls for a while after, see LampRules.showControls)
    @Published private(set) var confirmedAt: Date?
    var showsControls: Bool { LampRules.showControls(home: home, sinceConfirmed: confirmedAt.map { Date().timeIntervalSince($0) }) }

    /// every message to the iPhone, newest first (kept across launches), so it can be seen whether night-time
    /// steps reach the lamp while the watch app is in the background
    struct Contact: Codable, Identifiable {
        var id: Double { at.timeIntervalSince1970 }
        let at: Date
        let ok: Bool
        let background: Bool
        let what: String
    }
    @Published private(set) var contacts: [Contact] = {
        guard let d = UserDefaults.standard.data(forKey: "lampContacts") else { return [] }
        return (try? JSONDecoder().decode([Contact].self, from: d)) ?? []
    }()

    private var lastCheck = Date.distantPast
    private var pending: [String: Any]?
    private var pendingByUser = true
    /// an automatic change (sunrise, wind-down, asleep) that could not get through; sent again when the app comes
    /// to the front (the iPhone is reachable for sure then)
    private var deferred: (params: [String: Any], at: Date)?
    private var sending = false
    private var lastLocalChange = Date.distantPast
    /// the lamp panel is on screen (F16 never switches on under it)
    var panelOpen = false
    /// F16: the first and the last time the iPhone answered that no bulb replied (you are away); nil while at home
    private var awaySince: Date? {
        get { UserDefaults.standard.object(forKey: "lampAwaySince") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lampAwaySince") }
    }
    private var awayLast: Date? {
        get { UserDefaults.standard.object(forKey: "lampAwayLast") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lampAwayLast") }
    }
    /// when you last changed the lamp yourself (F6 never switches off over it)
    private(set) var userChangedAt: Date?
    /// F16: when you last switched the lamp off yourself
    private(set) var userOffAt: Date? {
        get { UserDefaults.standard.object(forKey: "lampUserOffAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lampUserOffAt") }
    }
    private static let cacheKey = "lampLastState", cacheTimeKey = "lampLastStateTime"

    init() {
        let d = UserDefaults.standard
        if let cached = d.dictionary(forKey: Self.cacheKey), Date().timeIntervalSince1970 - d.double(forKey: Self.cacheTimeKey) < 15 * 60 {
            state = LampLink.State(cached)
            if state.home { problem = nil }
        }
    }

    private func remember(_ s: LampLink.State) {
        guard s.home else { return }
        UserDefaults.standard.set(s.dictionary, forKey: Self.cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheTimeKey)
    }

    /// ask the iPhone for the lamp state (at most every 10 s unless forced)
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheck) > 10 else { return }
        lastCheck = Date()
        Task { await send([LampLink.commandKey: LampLink.status]) }
    }

    /// change the lamps; rapid changes (crown, slider) are coalesced so only the latest goes out
    func set(_ params: [String: Any], byUser: Bool = true) {
        if byUser {
            LampAutomation.shared.userChanged()      // you took over: sunrise / wind-down step aside
            userChangedAt = Date()
            if params["state"] as? Bool == false { userOffAt = Date() }
        }
        // any newer change supersedes an older automatic step still waiting to be retried: after yours it must
        // never be sent, and after a newer automatic one (the alarm's full light) neither (an "off, you fell
        // asleep" from earlier would otherwise follow it when you raise the wrist)
        deferred = nil
        lastLocalChange = Date()
        apply(params)
        pending = params
        pendingByUser = byUser
        flush()
    }

    /// the app came to the front: send an automatic change that failed in the background (if under 30 min old)
    func retryDeferred() {
        guard let d = deferred else { return }
        deferred = nil
        guard Date().timeIntervalSince(d.at) < 30 * 60, pending == nil else { return }
        set(d.params, byUser: false)
    }

    /// on / off. F22: switching on brings back your own last light for this time of day (evening after dark,
    /// daytime otherwise); off is always just off
    func toggle() {
        guard !state.on else { set(["state": false]); return }
        let memory = LampAutomation.shared.switchOnMemoryOn
            ? UserDefaults.standard.dictionary(forKey: Self.memoryKey(dark: Sun.darkHere())) : nil
        set(LampRules.switchOn(memory: memory))
    }

    /// F22: one memory for the evening (after dark) and one for the day
    static func memoryKey(dark: Bool) -> String { dark ? "lampMemoryEvening" : "lampMemoryDay" }
    /// one slider for everything, like Control Center: 0 is off, anything above sets the brightness (10...100 %)
    func setLevel(_ level: Double) {
        if level < 0.02 { if state.on { set(["state": false]) }; return }
        let pct = min(100, max(10, Int((level * 100).rounded())))
        if !state.on || pct != state.dimming { set(["state": true, "dimming": pct]) }
    }
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
        let byUser = pendingByUser
        pending = nil
        sending = true
        Task {
            let ok = await send([LampLink.commandKey: LampLink.set, LampLink.paramsKey: p], byUser: byUser)
            // a failed automatic step is kept for a retry only if nothing newer is waiting behind it
            if !ok && !byUser && pending == nil { deferred = (p, Date()) }
            // F22: a light you set and the lamp took becomes this time of day's memory (never an automatic one,
            // and only once it arrived, so a failed change is not remembered)
            if ok && byUser && pending == nil, let m = LampRules.memory(of: state) {
                UserDefaults.standard.set(m, forKey: Self.memoryKey(dark: Sun.darkHere()))
            }
            sending = false
            flush()
        }
    }

    /// one message to the iPhone: waits for reachability, retries, then takes the reply in
    @discardableResult
    private func send(_ message: [String: Any], byUser: Bool = true) async -> Bool {
        inFlight += 1
        defer { inFlight -= 1 }
        let background = WKApplication.shared().applicationState != .active
        let what = (message[LampLink.commandKey] as? String == LampLink.status ? "check" : "change") + (byUser ? "" : " (auto)")
        var lastError = "The iPhone did not answer. Open Sage on the iPhone and retry."
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(attempt == 1 ? 300 : 900)) }
            guard await reachable(within: attempt == 0 ? 3 : 1) else {
                lastError = "iPhone not reachable. Keep it nearby with Bluetooth on."
                continue
            }
            if let reply = await Self.message(message) {
                take(LampLink.State(reply))
                note(Contact(at: Date(), ok: true, background: background, what: what))
                return true
            }
        }
        note(Contact(at: Date(), ok: false, background: background, what: what))
        // a failed status check says we are not home; a failed change you made must not leave the panel showing a
        // state the lamp never took: fall back to what it last confirmed and say so. A failed automatic change is
        // kept quietly and sent again later (no buzz at night).
        if message[LampLink.commandKey] as? String == LampLink.status {
            state.home = false
        } else if pending == nil && byUser {
            if let c = confirmed { state = c }
            failedAt = Date()
        }
        problem = lastError
        return false
    }

    private func note(_ c: Contact) {
        contacts.insert(c, at: 0)
        if contacts.count > 40 { contacts.removeLast(contacts.count - 40) }
        if let d = try? JSONEncoder().encode(contacts) { UserDefaults.standard.set(d, forKey: "lampContacts") }
    }

    private func take(_ s: LampLink.State) {
        // keep what the user just set: replies (and the bulbs' own reports) lag behind the slider, and taking
        // them over would make it jump back after release
        if pending == nil && Date().timeIntervalSince(lastLocalChange) > 2.5 { state = s }
        else { state.home = s.home; state.count = s.count }
        problem = s.home ? nil : "No lamp answered. Open Sage on the iPhone once and allow Local Network, then retry."
        if s.home { confirmed = s; confirmedAt = Date() }
        remember(state)
        // F16: only the iPhone's own answer "no bulb replied" counts as away; an iPhone out of Bluetooth range in
        // another room does not (that never reaches here), so sitting at home is never taken for an arrival
        if !s.home {
            if awaySince == nil { awaySince = Date() }
            awayLast = Date()
        } else if let first = awaySince {
            let last = awayLast ?? first
            awaySince = nil; awayLast = nil
            LampAutomation.shared.arrived(awaySpan: last.timeIntervalSince(first), sinceAway: Date().timeIntervalSince(last))
        }
    }

    private func reachable(within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let s = WCSession.default
            if WCSession.isSupported(), s.activationState == .activated, s.isReachable { return true }
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private static func message(_ m: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { cont in
            WCSession.default.sendMessage(m, replyHandler: { cont.resume(returning: $0) },
                                          errorHandler: { _ in cont.resume(returning: nil) })
        }
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
    /// true while a finger is down; unlike `touching` it resets by itself when the system cancels the touch (a
    /// notification, the wrist going down), where onEnded never runs
    @GestureState private var fingerDown = false
    @State private var moved = false
    @State private var longFired = false
    @State private var lifted = false
    @State private var overshoot: CGFloat = 0        // rubber band: + past the top, - past the bottom
    @State private var lastEdge = -1
    @State private var colours = false
    @State private var appeared = false
    @State private var crown: Double = 0             // the crown turns endlessly: only its movement is used
    @State private var showValue = false
    @State private var pressTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var showFailure = false
    @State private var failureTask: Task<Void, Never>?
    @State private var zoom: CGFloat = 1             // colour wheel: the crown zooms out to see all of it
    @State private var lastUse = Date()              // closes itself after a while unused, as Control Center does
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase

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
            if lamp.showsControls {
                content.overlay(alignment: .top) { if !lamp.home { reconnecting } }
            } else {
                unavailable
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    if colours { closeColours() } else { dismiss() }
                } label: {
                    Image(systemName: colours ? "chevron.backward" : "xmark")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(Text(colours ? "Back to brightness" : "Close"))
            }
        }
        .onAppear { lamp.panelOpen = true }
        .onDisappear { lamp.panelOpen = false }
        // F25: the wrist goes down, the panel goes away; the next raise shows the face
        .onChange(of: phase) { _, p in
            if LampRules.closeOnWristDown(active: p == .active, touching: touching) { dismiss() }
        }
        // on both views: the "not reachable" screen must not keep the app in front forever either
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if LampRules.idleClose(idle: Date().timeIntervalSince(lastUse), touching: touching, colours: colours) {
                    dismiss(); return
                }
            }
        }
    }

    /// not at home, or the iPhone could not reach the lamps: say why, offer a retry
    /// a short drop while the panel is open: controls stay, this says the watch is reaching the lamp again
    private var reconnecting: some View {
        // a static symbol, not a spinner: the HIG asks watch apps to avoid indeterminate progress indicators, and
        // the controls under it work (they are what you should look at)
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FaceGeometry.Palette.sageLight)
            Text("Reconnecting…").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color(white: 0.12).opacity(0.94)))
        .padding(.top, 34)
        .allowsHitTesting(false)
        .task {
            // it says reconnecting, so it keeps trying while it shows (cancelled as soon as the lamp answers)
            var lastTry = Date.distantPast
            while !Task.isCancelled {
                if LampRules.retryReconnect(sinceLastTry: Date().timeIntervalSince(lastTry), busy: lamp.busy) {
                    lastTry = Date()
                    lamp.refresh(force: true)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            if lamp.busy || lamp.problem == nil || lamp.problem == "Checking…" {
                ProgressView()                                  // moving, so it never looks frozen
                Text("Checking…").font(.system(size: 13)).foregroundStyle(FaceGeometry.Palette.ivory)
            } else {
                Image(systemName: "lightbulb.slash").font(.system(size: 26)).foregroundStyle(FaceGeometry.Palette.sage)
                Text(lamp.problem ?? "")
                    .font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(FaceGeometry.Palette.ivory)
                Button("Retry") { lastUse = Date(); lamp.refresh(force: true) }
            }
        }
        .onAppear { lamp.refresh(force: true) }
    }

    private var content: some View {
        GeometryReader { geo in
            // the whole display is the slider: inset a hair, corners following the display's own
            let w = geo.size.width - 6, h = geo.size.height - 6
            ZStack {
                capsule(width: w, height: h)
                    .scaleEffect(colours && !reduceMotion ? 0.5 : 1)
                    .opacity(colours ? 0 : 1)
                    .blur(radius: colours && !reduceMotion ? 6 : 0)
                    .allowsHitTesting(!colours)
                valueLabel(fillHeight: 3 + h * level)
                    .opacity(showValue && !colours ? 1 : 0)
                    .allowsHitTesting(false)
                if colours {
                    Honeycomb(state: lamp.state, size: geo.size, reduceMotion: reduceMotion, zoom: zoom, pick: choose, cancel: closeColours)
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .scale(scale: 0.45).combined(with: .opacity),
                                                  removal: .scale(scale: 1.2).combined(with: .opacity)))
                }
                failureNote
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .digitalCrownRotation($crown, from: -1_000_000, through: 1_000_000, by: 1, sensitivity: .low,
                              isContinuous: true, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { old, v in
            let delta = v - old
            guard abs(delta) < 50 else { return }            // ignore a jump of the binding itself
            if colours {
                // in the colour wheel the crown zooms, as on the app grid: down shows all 61, up brings them close
                let next = min(1, max(0.42, zoom + CGFloat(delta) * 0.012))
                if next != zoom && (next == 1 || next == 0.42) { WKInterfaceDevice.current().play(.click) }
                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.9)) { zoom = next }
                return
            }
            guard !touching else { return }
            crownBrightness(by: delta)
        }
        .onChange(of: lamp.failedAt) { _, t in
            guard t != nil else { return }
            WKInterfaceDevice.current().play(.failure)
            withAnimation(.easeOut(duration: 0.2)) { showFailure = true }
            // a second failure restarts the 2.5 s; the first one's timer must not hide the new note early
            failureTask?.cancel()
            failureTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.3)) { showFailure = false }
            }
        }
        .onChange(of: crown) { _, _ in lastUse = Date() }
        .onChange(of: colours) { _, _ in lastUse = Date() }
        .onAppear {
            lamp.refresh(force: true)
            // the fill rises into place as the panel opens
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82).delay(0.12)) { appeared = true }
        }
    }

    /// The percentage, split where the fill edge crosses it: dark over the fill, white over the track (as Control
    /// Center does), so it never flips colour as the fill passes through it.
    private func valueLabel(fillHeight: CGFloat) -> some View {
        let text = Text(level > 0 ? "\(Int((level * 100).rounded()))%" : "Off")
            .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
            .contentTransition(.numericText(value: level))
        return ZStack {
            text.foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            text.foregroundStyle(Color.black.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(alignment: .bottom) { Rectangle().frame(height: max(0, fillHeight)) }
        }
    }

    /// a short note when a change did not reach the lamps; the slider has already gone back to their real state
    private var failureNote: some View {
        VStack {
            Label("Lamp didn't respond", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color(white: 0.12).opacity(0.94)))
                .padding(.top, 34)
            Spacer()
        }
        .opacity(showFailure ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(!showFailure)
    }

    private func capsule(width w: CGFloat, height h: CGFloat) -> some View {
        let stretch = abs(overshoot)
        let shape = RoundedRectangle(cornerRadius: min(w, h) * 0.2, style: .continuous)
        return ZStack(alignment: .bottom) {
            // the track brightens a touch while held (the full-screen stand-in for Control Center's lift)
            Rectangle().fill(Color.white.opacity(lifted ? 0.22 : 0.16))
            Rectangle().fill(Self.tint(lamp.state)).frame(height: h * level)
            Image(systemName: level > 0 ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(level > 0.12 ? Color.black.opacity(0.55) : Color.white.opacity(0.8))
                .contentTransition(.symbolEffect(.replace))
                .padding(.bottom, 20)
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        // past either end the whole slider stretches a little away from the fixed edge, then springs back
        .scaleEffect(x: 1 - stretch / h * 0.3, y: 1 + stretch / h, anchor: overshoot > 0 ? .bottom : .top)
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 0)
            .updating($fingerDown) { _, down, _ in down = true }
            .onChanged { touch($0, height: h) }
            .onEnded { _ in release() })
        // a touch the system cancelled never reaches onEnded; `touching` would stick and block the idle and
        // wrist-down close for good. If onEnded has not run shortly after the finger state reset, it was a cancel:
        // end it without counting it as a tap (a cancel must never switch the lamp)
        .onChange(of: fingerDown) { _, down in
            guard !down, touching else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                if touching && !fingerDown { cancelTouch() }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Lamp"))
        .accessibilityValue(Text(level > 0 ? "\(Int((level * 100).rounded())) percent" : "Off"))
        .accessibilityAdjustableAction { dir in
            lastUse = Date()                             // VoiceOver use is use: the panel must not close under it
            lamp.setLevel(min(1, max(0, modelLevel + (dir == .increment ? 0.1 : -0.1))))
        }
        .accessibilityAction { lastUse = Date(); lamp.toggle() }
        .accessibilityAction(named: Text("Colours")) { lastUse = Date(); withAnimation { colours = true } }
    }

    private func touch(_ g: DragGesture.Value, height h: CGFloat) {
        lastUse = Date()
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
        overshoot = reduceMotion ? 0 : Self.rubber(CGFloat(raw - clamped) * h, limit: h * 0.07)
        let edge = clamped <= 0 ? 0 : clamped >= 1 ? 1 : -1
        if edge != -1 && edge != lastEdge { WKInterfaceDevice.current().play(.click) }
        lastEdge = edge
        dragLevel = clamped
        lamp.setLevel(clamped)
    }

    /// the system took the touch away: undo the press look, keep whatever level the drag had already set, no tap
    private func cancelTouch() {
        pressTask?.cancel()
        touching = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { overshoot = 0 }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { lifted = false; dragLevel = nil }
        if moved { reveal(holding: false) }
        // the wrist went down mid-touch: the close that waited for the finger happens now
        if LampRules.closeOnWristDown(active: phase == .active, touching: false) { dismiss() }
    }

    private func release() {
        guard touching else { return }                   // once per touch
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

    /// one crown detent = 1 %. Below the 10 % minimum the next turn down switches off, the next turn up from off
    /// starts at 10 %; reaching 100 % or off gives a click, like a control hitting its end.
    private func crownBrightness(by delta: Double) {
        let now = modelLevel
        var next = now + delta / 100
        if delta < 0 && now <= 0.1 { next = 0 }
        if delta > 0 && now == 0 { next = 0.1 }
        next = min(1, max(0, next))
        guard next != now else { return }
        if (next == 0 || next == 1) { WKInterfaceDevice.current().play(.click) }
        withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) { lamp.setLevel(next) }
        reveal(holding: false)
    }

    private func choose(_ s: Swatch) {
        lastUse = Date()
        if let id = Honeycomb.cells.first(where: { $0.swatch == s })?.id { Honeycomb.recent = LampRules.recents(Honeycomb.recent, adding: id) }
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
        zoom = 1
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
/// edges. A colour wheel: whites in the middle (warm to cool around the centre), then rings of 12, 18 and 24 hues in
/// colour-wheel order, from soft pastels to fully saturated as they go outward (61 colours).
/// It blooms out ring by ring; tapping empty space goes back to the slider.
struct Honeycomb: View {
    let state: LampLink.State
    let size: CGSize
    var reduceMotion = false
    var zoom: CGFloat = 1
    let pick: (Swatch) -> Void
    let cancel: () -> Void

    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var bloomed = false
    @State private var panning = false
    /// F21: read once per opening, not 61 times a frame while panning
    @State private var recentIDs = Honeycomb.recent

    static let diameter: CGFloat = 42

    /// F21: the colours chosen last (cell ids, newest first), kept across launches
    static var recent: [Int] {
        get { UserDefaults.standard.array(forKey: "lampRecentColours") as? [Int] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "lampRecentColours") }
    }
    static let minHitRadius: CGFloat = 15
    static let pitch: CGFloat = 47

    struct Cell: Identifiable {
        let id: Int
        let pos: CGPoint
        let ring: Int
        let swatch: Swatch
        let name: String          // what VoiceOver says
    }

    static let hueNames = ["Red", "Orange", "Yellow", "Lime", "Green", "Mint", "Cyan", "Azure", "Blue", "Violet", "Magenta", "Pink"]
    static let ringNames = [2: "Pastel", 3: "Soft", 4: "Vivid"]
    static let whiteNames = [2200: "Candle", 2700: "Warm white", 3000: "Soft white", 3500: "White", 4200: "Neutral white",
                             5200: "Cool white", 6500: "Daylight"]

    /// rings around the centre; saturation per colour ring, pastel inside, vivid at the edge
    static let rings = 4
    static let saturation: [Int: CGFloat] = [2: 0.4, 3: 0.72, 4: 1]

    static let cells: [Cell] = {
        var raw: [(p: CGPoint, ring: Int, angle: Double)] = []
        for q in -rings...rings {
            for r in -rings...rings where abs(q + r) <= rings {
                let x = pitch * (CGFloat(q) + CGFloat(r) / 2), y = pitch * CGFloat(r) * sqrt(3) / 2
                var a = atan2(Double(x), Double(-y))            // 0 at the top, clockwise
                if a < 0 { a += 2 * .pi }
                raw.append((CGPoint(x: x, y: y), max(abs(q), abs(r), abs(q + r)), a))
            }
        }
        let whites = [2200, 3000, 3500, 4200, 5200, 6500]
        var out: [Cell] = [], i = 0
        for c in raw.sorted(by: { ($0.ring, $0.angle) < ($1.ring, $1.angle) }) {
            let s: Swatch, name: String
            switch c.ring {
            case 0: s = .white(2700); name = "Warm white"
            case 1: s = .white(whites[i]); name = whiteNames[whites[i]] ?? "White"; i += 1
            default:
                let h = c.angle / (2 * .pi)
                let rgb = hue(h, saturation: saturation[c.ring] ?? 1)
                s = .colour(rgb.0, rgb.1, rgb.2)
                name = "\(ringNames[c.ring] ?? "") \(hueNames[Int((h * 12).rounded()) % 12].lowercased())"
            }
            out.append(Cell(id: out.count, pos: c.p, ring: c.ring, swatch: s, name: name))
        }
        return out
    }()

    static func hue(_ h: Double, saturation: CGFloat = 1) -> (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(hue: h, saturation: saturation, brightness: 1, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    var body: some View {
        ZStack {
            ForEach(Self.cells) { bubble($0) }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        // one gesture decides: a touch that travels is a pan and never picks; a touch that stays put is a tap,
        // on a bubble it picks that colour, on empty space it goes back to the slider
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !panning && hypot(g.translation.width, g.translation.height) > 6 { panning = true }
                guard panning else { return }
                pan = CGSize(width: bound(panBase.width + g.translation.width, Self.panLimit.width * zoom),
                             height: bound(panBase.height + g.translation.height, Self.panLimit.height * zoom))
            }
            .onEnded { g in
                defer { panning = false }
                if panning {
                    let l = CGSize(width: Self.panLimit.width * zoom, height: Self.panLimit.height * zoom)
                    panBase = CGSize(width: min(l.width, max(-l.width, pan.width)), height: min(l.height, max(-l.height, pan.height)))
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { pan = panBase }
                } else if let cell = hit(g.location) {
                    pick(cell.swatch)
                } else {
                    cancel()
                }
            })
        .onChange(of: zoom) { _, z in
            // keep the view inside the smaller grid when zooming out
            let l = CGSize(width: Self.panLimit.width * z, height: Self.panLimit.height * z)
            panBase = CGSize(width: min(l.width, max(-l.width, panBase.width)), height: min(l.height, max(-l.height, panBase.height)))
            if !panning { pan = panBase }
        }
        .onAppear {
            // open centred on the colour that is set, as the app grid opens on the last app; with the recent ones
            // too when they fit around it (LampRules.openCentre, tested)
            let cur = Self.cells.first(where: { $0.swatch.matches(state) })?.pos
            let rec = recentIDs.compactMap { id in Self.cells.first(where: { $0.id == id })?.pos }
            let c = LampRules.openCentre(current: cur, recents: rec, half: centreZone)
            panBase = CGSize(width: -c.x, height: -c.y)
            pan = panBase
            bloomed = true
        }
    }

    /// far enough that any bubble, the outer ring included, can be brought to the full-size middle
    static let panLimit = CGSize(width: CGFloat(rings) * pitch, height: CGFloat(rings) * pitch * sqrt(3) / 2)

    /// free inside the limit, rubber band beyond it
    private func bound(_ v: CGFloat, _ lim: CGFloat) -> CGFloat {
        guard abs(v) > lim else { return v }
        let extra = LampPanel.rubber(abs(v) - lim, limit: 28)
        return v > 0 ? lim + extra : -lim - extra
    }

    /// the bubble under a tap, by its drawn (fisheye) position and size
    private func hit(_ location: CGPoint) -> Cell? {
        let p = CGPoint(x: location.x - size.width / 2, y: location.y - size.height / 2)
        return Self.cells
            .map { c -> (Cell, CGFloat, CGFloat) in
                let f = fisheye(CGPoint(x: c.pos.x * zoom + pan.width, y: c.pos.y * zoom + pan.height))
                // at least ~30 pt across, however small the bubble is drawn at the edge or zoomed out;
                // where targets overlap, the nearest centre wins
                return (c, hypot(p.x - f.point.x, p.y - f.point.y), max(Self.diameter / 2 * f.scale * zoom + 3, Self.minHitRadius))
            }
            .filter { $0.1 <= $0.2 }
            .min { $0.1 < $1.1 }?.0
    }

    /// half extents of the zone where bubbles are drawn full size (the fisheye's centre)
    private var centreZone: CGSize { CGSize(width: size.width / 2 - Self.diameter * 0.75, height: size.height / 2 - Self.diameter * 0.75) }

    private func bubble(_ cell: Cell) -> some View {
        let f = fisheye(CGPoint(x: cell.pos.x * zoom + pan.width, y: cell.pos.y * zoom + pan.height))
        let selected = cell.swatch.matches(state)
        // F21: a recent colour (not the one set, which has its ring) carries a small dot, light on every colour
        let recent = !selected && recentIDs.contains(cell.id)
        return Circle().fill(cell.swatch.color)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: selected ? 3 : 0))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: selected ? 1 : 0).padding(3))
            .overlay(alignment: .bottom) {
                if recent {
                    Circle().fill(Color.white).overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                        .frame(width: 7, height: 7).padding(.bottom, 6)
                }
            }
        .frame(width: Self.diameter, height: Self.diameter)
        .scaleEffect((bloomed || reduceMotion ? f.scale : 0.15) * zoom)
        .opacity(bloomed ? 1 : 0)
        .position(x: size.width / 2 + (bloomed || reduceMotion ? f.point.x : 0), y: size.height / 2 + (bloomed || reduceMotion ? f.point.y : 0))
        .animation(reduceMotion ? .easeInOut(duration: 0.2)
                   : .spring(response: 0.5, dampingFraction: 0.74).delay(Double(cell.ring) * 0.04), value: bloomed)
        .accessibilityElement()
        .accessibilityLabel(Text(recent ? "\(cell.name), recent" : cell.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pick(cell.swatch) }
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
