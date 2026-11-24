import SwiftUI

@main
struct SageWatchApp: App {
    @StateObject private var health = HealthStore()
    @StateObject private var alarm = SmartAlarm()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            FaceScreen()
                .environmentObject(health)
                .environmentObject(alarm)
                .task { await health.start() }
                .onAppear { alarm.scheduleNext() }
                .onChange(of: phase) { _, p in if p == .active { alarm.scheduleNext() } }
        }
    }
}

/// The face, full-screen. Active: 30 fps for the digit morph and the seconds runner.
/// Always-on: one frame a minute, and the renderer drops the dial, numerals and subdials.
struct FaceScreen: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var alarm: SmartAlarm
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        ZStack {
            if dimmed {
                TimelineView(.everyMinute) { tl in face(tl.date) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in face(tl.date) }
            }
            if alarm.ringing { WakeOverlay { alarm.stop() } }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    private func face(_ date: Date) -> some View {
        Canvas { ctx, size in draw(&ctx, size, date) }
            .accessibilityElement()
            .accessibilityLabel(Text(date.formatted(date: .omitted, time: .shortened)))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ date: Date) {
        let state = FaceState(date: date, mode: FaceMode.auto(date), steps: health.steps, heartRate: health.heartRate, dimmed: dimmed)
        FaceRenderer.draw(&ctx, size: size, state: state)
    }
}

/// Shown while the silent alarm taps: a soft sage sunrise and one large target to stop it.
struct WakeOverlay: View {
    let stop: () -> Void
    @State private var glow = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0xC9A877).opacity(glow ? 0.45 : 0.15), .black.opacity(0.85)], center: .bottom, startRadius: 4, endRadius: 220)
            VStack(spacing: 8) {
                Text("Good morning").font(.custom("PlayfairDisplay-Regular", size: 22)).foregroundStyle(FaceGeometry.Palette.ivory)
                Text("light sleep · woke gently").font(.system(size: 12)).foregroundStyle(FaceGeometry.Palette.sage)
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
