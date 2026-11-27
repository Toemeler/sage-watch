import SwiftUI
import WatchKit

@main
struct SageWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var health = HealthStore()
    @StateObject private var alarm = SmartAlarm.shared
    @StateObject private var recorder = Recorder.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            FaceScreen()
                .environmentObject(health)
                .environmentObject(alarm)
                .environmentObject(recorder)
                .task { await health.start() }
                .onAppear {
                    LampAutomation.shared.scheduleWindDown()
                    LampAutomation.shared.scheduleBedtimeTap()
                    alarm.scheduleNext()
                    if recorder.keepRunning { recorder.start() }
                }
                .onChange(of: phase) { _, p in
                    guard p == .active else { return }
                    LampAutomation.shared.scheduleWindDown()
                    LampAutomation.shared.scheduleBedtimeTap()
                    alarm.scheduleNext()
                    if recorder.keepRunning && !recorder.isRunning { recorder.start() }
                    Outbox.shared.resendAll()
                }
        }
    }
}

/// The face, full-screen. Active: the dial drawn once, the runner and time at 20 fps. Always-on and the bedside
/// clock: one frame a minute. Long-press opens the menu, swipe up or crown up the lamp, crown down a nap,
/// double tap toggles the lamp. While the alarm rings, only Stop works (and double tap stops it).

struct FaceScreen: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var alarm: SmartAlarm
    @EnvironmentObject private var recorder: Recorder
    @ObservedObject private var activity = ActivityMonitor.shared
    @Environment(\.isLuminanceReduced) private var dimmed
    @State private var showControls = false
    @ObservedObject private var lamp = LampModel.shared
    @State private var showLamp = false
    @ObservedObject private var audio = AudioModel.shared
    @ObservedObject private var automation = LampAutomation.shared
    @State private var showMusic = false
    @State private var faceCrown: Double = 0
    @State private var crownBase: Double = 0
    @State private var crownMovedAt = Date.distantPast
    @State private var napNote: String?              // "Nap: watching for sleep" with Undo, for 3 s (F9)
    @State private var napNoteTask: Task<Void, Never>?
    @State private var napLength: Double?            // F17: while the nap note shows, the crown sets the nap's length
    @State private var napEditFrom = Date.distantFuture
    @State private var noteUndo: (() -> Void)?        // what Undo on the current note does (nil: no Undo)
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            TimelineView(.everyMinute) { minute in
                if dimmed || Self.bedside(minute.date) {
                    // always-on and bedside: one frame a minute
                    face(minute.date)
                } else {
                    // static layers drawn once; only the runner and the live layer follow the clock, at 20 fps
                    // (the runner steps 5 times a second; 20 fps keeps its fade and the digit morph smooth)
                    ZStack {
                        layer([.base])
                        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in layer([.runner], tl.date) }
                        layer([.marks])
                        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in layer([.live], tl.date) }
                    }
                    // the spoken time follows the minute (it was fixed at the first draw before)
                    .accessibilityElement()
                    .accessibilityLabel(Text(minute.date.formatted(date: .omitted, time: .shortened)))
                }
            }
            doubleTapTarget
            if let note = napNote {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        // on the bedside clock the note is red too, so it never lights the room
                        let night = Self.bedside(Date())
                        Text(note).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(night ? FaceRenderer.bedsideRed : FaceGeometry.Palette.ivory)
                        if let undo = noteUndo {
                            // a target a sleepy finger can hit: ~44 x 32 pt, not just the word
                            Button { undo(); hideNapNote() } label: {
                                Text("Undo").font(.system(size: 14, weight: .semibold))
                                    .frame(minWidth: 44, minHeight: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(night ? FaceRenderer.bedsideRed : FaceGeometry.Palette.sageLight)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color(white: Self.bedside(Date()) ? 0.05 : 0.12).opacity(0.95)))
                    .padding(.bottom, 18)
                }
                .transition(.opacity)
            }
            if recorder.isRunning && !dimmed && !Self.bedside(Date()) {
                VStack {
                    Circle().fill(FaceGeometry.Palette.sage).frame(width: 5, height: 5).padding(.top, 3)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            if !dimmed && !alarm.ringing && !alarm.testing {
                // tap the music indicator for pause, skip and back
                if audio.playing {
                    GeometryReader { geo in
                        let r = FaceRenderer.viewRect(FaceRenderer.musicRect.insetBy(dx: -20, dy: -14), in: geo.size)
                        Color.clear.contentShape(Rectangle())
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .onTapGesture { showMusic = true }
                            .accessibilityElement()
                            .accessibilityLabel(Text("Now playing"))
                            .accessibilityHint(Text("Pause, skip and volume"))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { showMusic = true }
                    }
                    .ignoresSafeArea()
                }
            }
            if alarm.ringing {
                WakeOverlay(subtitle: alarm.ringingBlock == .nap ? "one cycle done · woke gently" : "light sleep · woke gently") { alarm.stop() }
            } else if alarm.testing {
                WakeOverlay(title: "Test alarm", subtitle: "from the iPhone · stops by itself") { alarm.stopTest() }
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        // the face is the clock: hide the system time in the top-right corner (underscored but public SwiftUI API, watchOS 6+)
        ._statusBarHidden(true)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.8) { if !alarmActive { showControls = true } }
        // swipe up: the lamp panel, when at home (asks the iPhone first if it does not know yet)
        .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { g in
            guard !alarmActive, g.translation.height < -40, abs(g.translation.width) < abs(g.translation.height) else { return }
            showLamp = true   // the panel says why when the lamps cannot be reached
        })
        // turning the crown on the face opens the lamp: a deliberate turn, not a brush, and never during a sleep
        // block (a sleeve or the pillow can turn the crown; the panel would then change the light in the dark)
        .focusable()
        .focusEffectDisabled()
        .digitalCrownRotation($faceCrown, from: -1_000_000, through: 1_000_000, sensitivity: .low,
                              isContinuous: true, isHapticFeedbackEnabled: false)
        .onChange(of: faceCrown) { _, v in
            guard !showLamp, !showControls, !showMusic, !dimmed, !alarmActive else { crownBase = v; return }
            if napLength != nil { adjustNapLength(crown: v); return }
            // a pause starts a new gesture; up opens the lamp, a long turn down starts a nap (FaceRules, tested)
            if Date().timeIntervalSince(crownMovedAt) > FaceRules.gesturePause { crownBase = v - (v - crownBase).clamped(to: -1...1) }
            crownMovedAt = Date()
            if Self.bedside(Date()) {
                // F12: on the bedside clock the crown is a night-light switch (never anything bright)
                switch FaceRules.bedsideCrown(delta: v - crownBase) {
                case .nightLight: crownBase = v; bedsideLamp(on: true)
                case .lampOff: crownBase = v; bedsideLamp(on: false)
                case .none: break
                }
                return
            }
            switch FaceRules.crownAction(delta: v - crownBase, sleeping: FaceMode.auto(Date()) == .sleeping) {
            case .startNap:
                crownBase = v
                startNapFromFace()
            case .openLamp:
                crownBase = v
                WKInterfaceDevice.current().play(.click)
                showLamp = true
            case .none:
                break
            }
        }
        .onChange(of: showLamp) { _, _ in crownBase = faceCrown }
        .onChange(of: automation.bedtimeTappedAt) { _, t in
            if t != nil { showNapNote("Bedtime · lamp still bright", undo: nil) }
        }
        .onAppear { lamp.refresh(force: true); audio.refresh(force: true) }
        .onChange(of: phase) { _, p in
            if p == .active { lamp.refresh(); audio.refresh(force: true); LampAutomation.shared.appBecameActive() }
        }
        // headphones and playback: AudioModel polls by itself while the app is in front
        .task { audio.startPolling() }
        .sheet(isPresented: $showMusic) { NowPlayingView() }
        // full screen: it slides up like the swipe that opens it, and vertical drags inside can't pull it away
        .fullScreenCover(isPresented: $showLamp) { NavigationStack { LampPanel(lamp: lamp) } }
        .sheet(isPresented: $showControls) {
            NavigationStack { RecorderControls().environmentObject(recorder).environmentObject(health) }
        }
    }

    private func face(_ date: Date) -> some View {
        Canvas { ctx, size in draw(&ctx, size, date) }
            .accessibilityElement()
            .accessibilityLabel(Text(date.formatted(date: .omitted, time: .shortened)))
    }

    /// charging at night (21:00–07:00): the face becomes a dim red bedside clock (F10)
    static func bedside(_ d: Date) -> Bool {
        FaceRules.bedside(hour: Calendar.current.component(.hour, from: d), charging: BatteryReader.read(d).charging)
    }

    /// F11: double tap (pinch twice, watchOS 11+ on watches that support it) toggles the lamp. The gesture needs a
    /// real button as the scene's primary action; this one is invisible and the decision is FaceRules.doubleTap.
    @ViewBuilder private var doubleTapTarget: some View {
        if #available(watchOS 11.0, *) {
            Button(action: lampDoubleTap) { Color.clear.frame(width: 2, height: 2) }
                .buttonStyle(.plain)
                .opacity(0.02)
                .handGestureShortcut(.primaryAction)
                .accessibilityHidden(true)       // VoiceOver has the lamp panel and its own actions
        }
    }

    /// the alarm (or a test) is tapping: the face's own gestures stand down so a sleepy fumble can only stop it
    private var alarmActive: Bool { alarm.ringing || alarm.testing }

    private func lampDoubleTap() {
        switch FaceRules.doubleTap(ringing: alarmActive, sleeping: FaceMode.auto(Date()) == .sleeping, dimmed: dimmed,
                                   bedside: Self.bedside(Date()), home: lamp.home) {
        case .stopAlarm:
            if alarm.ringing { alarm.stop() } else { alarm.stopTest() }
        case .toggleLamp:
            WKInterfaceDevice.current().play(.click)
            let on = !lamp.state.on
            lamp.toggle()
            showNapNote(on ? "Lamp on" : "Lamp off", undo: { lamp.toggle() })
        case .openLamp:
            showLamp = true
        case .none:
            break
        }
    }

    /// F12: crown up on the bedside clock → red night light at the bulb's minimum; crown down → lamp off
    private func bedsideLamp(on: Bool) {
        guard lamp.showsControls else {
            WKInterfaceDevice.current().play(.failure)
            showNapNote("Lamp not reachable")
            lamp.refresh(force: true)
            return
        }
        WKInterfaceDevice.current().play(.click)
        if on {
            lamp.set(FaceRules.nightLight)
            automation.nightLightStarted()
            showNapNote("Night light · 15 min", undo: { lamp.set(["state": false]) })
        } else {
            lamp.set(["state": false])
            showNapNote("Lamp off")
        }
    }

    /// F9: a long turn of the crown down starts a nap, with a short note and Undo
    private func startNapFromFace() {
        guard !alarm.ringing else { return }
        guard recorder.isRunning else {
            WKInterfaceDevice.current().play(.failure)
            showNapNote("Naps need Record on")
            return
        }
        alarm.napNow()
        WKInterfaceDevice.current().play(.start)
        showNapNote(Self.napText(alarm.napLength), undo: { alarm.cancelNap() })
        // F17: while the note shows, turning the crown sets the length. The turn that started the nap carries on
        // for a moment; it must not shorten the nap, so editing starts after a short pause in the turn.
        napLength = alarm.napLength
        napEditFrom = Date().addingTimeInterval(0.6)
    }

    static func napText(_ minutes: Double) -> String { "Nap · up to \(Int(minutes)) min" }

    /// F17: 4 detents per 5-minute step, up longer, down shorter (as crowns raise values); a click per step and
    /// none past the ends. Each step keeps the note (and its Undo) up for another 3 s.
    private func adjustNapLength(crown v: Double) {
        guard let m = napLength, Date() >= napEditFrom, alarm.napArmed else { crownBase = v; return }
        let steps = ((v - crownBase) / FaceRules.napStepDetents).rounded(.towardZero)
        guard steps != 0 else { return }
        crownBase += steps * FaceRules.napStepDetents
        let next = FaceRules.napLength(m, steps: Int(steps))
        guard next != m else { return }
        napLength = next
        alarm.setNapLength(next)
        WKInterfaceDevice.current().play(.click)
        keepNote(Self.napText(next))
    }

    private func showNapNote(_ text: String, undo: (() -> Void)? = nil) {
        napLength = nil                          // any other note ends the nap-length editing
        noteUndo = undo
        keepNote(text)
    }

    /// show `text` and (re)start the note's 3 s
    private func keepNote(_ text: String) {
        napNoteTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { napNote = text }
        napNoteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            hideNapNote()
        }
    }

    private func hideNapNote() {
        noteUndo = nil
        napLength = nil
        withAnimation(.easeIn(duration: 0.25)) { napNote = nil }
    }

    private func layer(_ layers: FaceRenderer.Layers, _ date: Date = .now) -> some View {
        Canvas { ctx, size in draw(&ctx, size, date, layers: layers) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ date: Date, layers: FaceRenderer.Layers = .all) {
        let power = BatteryReader.read(date)
        let state = FaceState(date: date, mode: FaceMode.auto(date), music: audio.playing, bedside: Self.bedside(date), dimmed: dimmed,
                              battery: power.percent, charging: power.charging)
        FaceRenderer.draw(&ctx, size: size, state: state, layers: layers)
    }

}

/// Battery for the plaque, read from the frame being drawn (at most every 15 s). A SwiftUI timer stored in the view
/// was recreated with every re-render of the view and so never fired, which left the plaque on the level at launch.
enum BatteryReader {
    private static var last: (at: Date, percent: Int?, charging: Bool)?

    static func read(_ now: Date) -> (percent: Int?, charging: Bool) {
        if let l = last, abs(now.timeIntervalSince(l.at)) < 15 { return (l.percent, l.charging) }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let state = device.batteryState
        let value = (now, FaceRenderer.batteryPercent(device.batteryLevel), state == .charging || state == .full)
        last = value
        return (value.1, value.2)
    }
}

/// Shown while the silent alarm taps: a soft sage sunrise and one large target to stop it.
struct WakeOverlay: View {
    var title = "Good morning"
    var subtitle = "light sleep · woke gently"
    let stop: () -> Void
    @State private var glow = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0xC9A877).opacity(glow ? 0.45 : 0.15), .black.opacity(0.85)], center: .bottom, startRadius: 4, endRadius: 220)
            VStack(spacing: 8) {
                Text(title).font(.custom("PlayfairDisplay-Regular", size: 22)).foregroundStyle(FaceGeometry.Palette.ivory)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(FaceGeometry.Palette.sage)
                Button(action: stop) {
                    Text("Stop").font(.headline).frame(maxWidth: .infinity)
                }
                .tint(FaceGeometry.Palette.sage)
                .padding(.top, 6)
                Text("or shake your wrist hard").font(.system(size: 11)).foregroundStyle(FaceGeometry.Palette.ivory.opacity(0.6))
            }
            .padding()
        }
        .onAppear { withAnimation(.easeInOut(duration: 2).repeatForever()) { glow = true } }
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
