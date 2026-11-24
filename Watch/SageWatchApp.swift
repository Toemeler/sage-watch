import SwiftUI

@main
struct SageWatchApp: App {
    @StateObject private var health = HealthStore()

    var body: some Scene {
        WindowGroup {
            FaceScreen()
                .environmentObject(health)
                .task { await health.start() }
        }
    }
}

/// The face, full-screen. Active: redraws every second. Always-on (luminance reduced): the system asks for one frame
/// per minute and the renderer drops the dial, numerals and subdials, like the prototype's always-on state.
struct FaceScreen: View {
    @EnvironmentObject private var health: HealthStore
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        TimelineView(.periodic(from: .now, by: dimmed ? 60 : 1)) { tl in
            Canvas { ctx, size in
                let state = FaceState(date: tl.date, mode: FaceMode.auto(tl.date), steps: health.steps, heartRate: health.heartRate, dimmed: dimmed)
                FaceRenderer.draw(&ctx, size: size, state: state)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .accessibilityElement()
        .accessibilityLabel(Text(Date.now.formatted(date: .omitted, time: .shortened)))
    }
}
