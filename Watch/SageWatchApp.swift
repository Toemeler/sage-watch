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
                    alarm.scheduleNext()
                    if recorder.keepRunning { recorder.start() }
                }
                .onChange(of: phase) { _, p in
                    guard p == .active else { return }
                    alarm.scheduleNext()
                    if recorder.keepRunning && !recorder.isRunning { recorder.start() }
                    Outbox.shared.resendAll()
                }
        }
    }
}

/// The face, full-screen. Active: 30 fps for the digit morph and the seconds runner.
/// Always-on: one frame a minute, and the renderer drops the dial, numerals and subdials.
/// Long-press opens the recorder controls.
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
    @State private var showMusic = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            if dimmed {
                TimelineView(.everyMinute) { tl in face(tl.date) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in face(tl.date) }
            }
            if recorder.isRunning && !dimmed {
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
        .onLongPressGesture(minimumDuration: 0.8) { showControls = true }
        // swipe up: the lamp panel, when at home (asks the iPhone first if it does not know yet)
        .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { g in
            guard g.translation.height < -40, abs(g.translation.width) < abs(g.translation.height) else { return }
            showLamp = true   // the panel says why when the lamps cannot be reached
        })
        .onAppear { lamp.refresh(force: true); audio.refresh(force: true) }
        .onChange(of: phase) { _, p in if p == .active { lamp.refresh(); audio.refresh(force: true) } }
        // while the face is up, check headphones and playback every 20 s
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if phase == .active { audio.refresh() }
            }
        }
        .sheet(isPresented: $showMusic) { NowPlayingView() }
        .sheet(isPresented: $showLamp) { NavigationStack { LampPanel(lamp: lamp) } }
        .sheet(isPresented: $showControls) {
            RecorderControls().environmentObject(recorder).environmentObject(health)
        }
    }

    private func face(_ date: Date) -> some View {
        Canvas { ctx, size in draw(&ctx, size, date) }
            .accessibilityElement()
            .accessibilityLabel(Text(date.formatted(date: .omitted, time: .shortened)))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ date: Date) {
        let power = BatteryReader.read(date)
        let state = FaceState(date: date, mode: FaceMode.auto(date), bpm: recorder.bpm ?? health.heartRate,
                              music: audio.playing, dimmed: dimmed,
                              battery: power.percent, charging: power.charging)
        FaceRenderer.draw(&ctx, size: size, state: state)
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
