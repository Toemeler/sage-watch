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
    @Environment(\.isLuminanceReduced) private var dimmed
    @State private var showControls = false
    @State private var battery: Int?
    @State private var charging = false
    private let batteryTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

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
            if alarm.ringing {
                WakeOverlay { alarm.stop() }
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
        .onAppear(perform: readBattery)
        .onReceive(batteryTick) { _ in readBattery() }
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
        // while recording, the face shows the live heart rate from the workout session
        let bpm = recorder.isRunning ? (recorder.bpm ?? health.heartRate) : health.heartRate
        let state = FaceState(date: date, mode: FaceMode.auto(date), steps: health.steps, heartRate: bpm, dimmed: dimmed,
                              battery: battery, charging: charging)
        FaceRenderer.draw(&ctx, size: size, state: state)
    }

    /// battery for the plaque, read every 30 s rather than every frame
    private func readBattery() {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        battery = FaceRenderer.batteryPercent(device.batteryLevel)
        charging = device.batteryState == .charging || device.batteryState == .full
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
            }
            .padding()
        }
        .onAppear { withAnimation(.easeInOut(duration: 2).repeatForever()) { glow = true } }
    }
}
