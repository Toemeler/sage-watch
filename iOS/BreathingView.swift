import SwiftUI
import UIKit

/// Live breathing from the watch: breaths per minute and the last 30 s of the breathing wave.
struct BreathingView: View {
    @ObservedObject private var live = LiveBreathing.shared

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(live.rate.map { String(Int($0.rounded())) } ?? "–")
                            .font(.system(size: 64, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ivory)
                        Text("breaths / min").font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    Text(live.status).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    BreathingWave(wave: live.wave, peaks: live.peaks)
                        .frame(height: 150)
                    HStack {
                        Text("30 s ago").font(.caption2).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("now").font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.vertical, 8)
            } footer: {
                Text("Sit or lie still and rest the arm with the watch on your chest or belly. Each breath tilts the wrist by a degree or two, and Sage picks that up from the watch's motion sensor 10 times a second. Dots mark each breath. While this screen is open Sage keeps running on the watch, also with its screen off, and it opens Sage there if needed. Not a medical measurement.")
            }
        }
        .navigationTitle("Live breathing")
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            live.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            live.stop()
        }
    }
}

/// The breathing wave, newest on the right, with a dot on each breath.
struct BreathingWave: View {
    let wave: [Double]
    let peaks: [Int]

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            var base = Path()
            base.move(to: CGPoint(x: 0, y: mid)); base.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(base, with: .color(Theme.hair), lineWidth: 1)
            guard wave.count > 1 else { return }
            let span = Double(BreathingDetector.window - 1)
            let mean = wave.reduce(0, +) / Double(wave.count)
            let top = max(4, wave.map { abs($0 - mean) }.max() ?? 4) * 1.15
            func point(_ i: Int) -> CGPoint {
                let x = size.width - (Double(wave.count - 1 - i) / span) * size.width
                let y = mid - (wave[i] - mean) / top * (size.height / 2)
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<wave.count { line.addLine(to: point(i)) }
            ctx.stroke(line, with: .color(Theme.sage), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            for i in peaks where i < wave.count {
                let p = point(i)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(Theme.ivory))
            }
        }
        .accessibilityLabel("Breathing wave of the last 30 seconds")
    }
}
