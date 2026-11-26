import SwiftUI

@main
struct SageApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @StateObject private var health = HealthStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(health)
                .preferredColorScheme(.dark)
                .task { await health.start() }
                // touch the bulbs once in the foreground, so iOS asks for Local Network now (it cannot ask in the background)
                .task { _ = await WizClient.status() }
        }
    }
}

enum Theme {
    static let bg = Color.black
    static let card = Color(hex: 0x121311)
    static let hair = Color(hex: 0x23261F)
    static let ivory = FaceGeometry.Palette.ivory
    static let sage = Color(hex: 0x9AB091)
    static let sageDark = Color(hex: 0x4E5F49)
    static let gold = Color(hex: 0xC9A877)
    static let muted = Color(hex: 0x8A877D)
    static let rem = Color(hex: 0xA9B9C9)
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font { .custom(italic ? "PlayfairDisplay-Italic" : "PlayfairDisplay-Regular", size: size) }
}

struct RootView: View {
    var body: some View {
        TabView {
            TodayView().tabItem { Label("Today", systemImage: "circle.circle") }
            SleepView().tabItem { Label("Sleep", systemImage: "moon") }
            PlanView().tabItem { Label("Plan", systemImage: "list.bullet") }
            FacesView().tabItem { Label("Faces", systemImage: "applewatch") }
            DataView().tabItem { Label("Data", systemImage: "waveform.path.ecg") }
        }
        .tint(Theme.sage)
    }
}

// MARK: - shared pieces

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hair, lineWidth: 1))
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .medium)).kerning(2).foregroundStyle(Theme.muted) }
}

func hm(_ minutes: Double) -> String { let m = Int(minutes); return "\(m / 60)h \(String(format: "%02d", m % 60))m" }

// MARK: - Today: the 24-hour ring

struct TodayView: View {
    @EnvironmentObject private var health: HealthStore
    @ObservedObject private var nights = NightStore.shared

    var body: some View {
        TimelineView(.everyMinute) { tl in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(tl.date)
                    DayRing(now: tl.date).frame(height: 260).frame(maxWidth: .infinity)
                    statsGrid
                }
                .padding(16)
            }
            .background(Theme.bg)
            .onAppear { nights.refresh() }
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        Card {
                            Eyebrow(text: "Last night")
                            if let n = nights.lastNight?.analysis {
                                Text(hm(n.summary.asleepMinutes)).font(Theme.serif(24)).foregroundStyle(Theme.ivory)
                                Text("\(clock(n.onset)) → \(clock(n.wake)) · \(n.completeCycles.count) cycles").font(.caption).foregroundStyle(Theme.muted)
                            } else {
                                Text("–").font(Theme.serif(24)).foregroundStyle(Theme.ivory)
                                Text("plan \(Plan.fmt(Plan.night.onset))–\(Plan.fmt(Plan.night.end))").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        Card {
                            Eyebrow(text: "Nap")
                            if let n = nights.lastNap?.analysis, Calendar.current.isDateInToday(Date(timeIntervalSince1970: n.onset)) {
                                Text(hm(n.summary.asleepMinutes)).font(Theme.serif(24)).foregroundStyle(Theme.ivory)
                                Text("\(clock(n.onset)) → \(clock(n.wake))").font(.caption).foregroundStyle(Theme.muted)
                            } else {
                                Text(Plan.fmt(Plan.nap.onset)).font(Theme.serif(24)).foregroundStyle(Theme.ivory)
                                Text("one cycle after you fall asleep").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
        }
    }

    private func header(_ d: Date) -> some View {
        let mode = FaceMode.auto(d)
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: d.formatted(.dateTime.day().month(.wide)))
                Text(greeting(d)).font(Theme.serif(26)).foregroundStyle(Theme.ivory)
            }
            Spacer()
            Text(mode.rawValue.capitalized).font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().stroke(Theme.hair))
                .foregroundStyle(Theme.ivory)
        }
    }

    private func greeting(_ d: Date) -> String {
        let h = Calendar.current.component(.hour, from: d)
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }
}

/// The app's signature: the whole day as one dial, with both sleep blocks and their gold smart-wake windows.
struct DayRing: View {
    let now: Date

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
        .accessibilityLabel(Text("Day ring with night sleep \(Plan.fmt(Plan.night.onset)) to \(Plan.fmt(Plan.night.wake)) and nap \(Plan.fmt(Plan.nap.onset)) to \(Plan.fmt(Plan.nap.wake))"))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
            let S = min(size.width, size.height), c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = S * 0.4, w = max(3, S * 0.045)
        func ang(_ m: Double) -> Angle { .degrees(m / 1440 * 360 - 90) }
        func arc(_ a: Double, _ b: Double, r: Double) -> Path {
            var p = Path(); p.addArc(center: c, radius: r, startAngle: ang(a), endAngle: ang(b > a ? b : b + 1440), clockwise: false); return p
        }
        for h in 0..<24 {
            let a = CGFloat(ang(Double(h) * 60).radians), r1 = R + w * 0.9, r2 = R + w * (h % 6 == 0 ? 1.9 : 1.35)
            var t = Path()
            t.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1)); t.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
            ctx.stroke(t, with: .color(h % 6 == 0 ? Theme.muted : Theme.hair), lineWidth: h % 6 == 0 ? 1.6 : 1)
        }
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)), with: .color(Color(hex: 0x1D201B)), lineWidth: w)
        ctx.stroke(arc(451, 1008, r: R - w * 1.4), with: .color(Theme.gold.opacity(0.28)), style: StrokeStyle(lineWidth: w * 0.35, lineCap: .round))
        let nOn = Plan.night.onset - 1440, nWake = Plan.night.wake - 1440
        ctx.stroke(arc(nOn, nWake, r: R), with: .color(Theme.sage), style: StrokeStyle(lineWidth: w, lineCap: .round))
        ctx.stroke(arc(Plan.nap.onset, Plan.nap.wake, r: R), with: .color(Theme.sage.opacity(0.75)), style: StrokeStyle(lineWidth: w, lineCap: .round))
        for (a, b) in [(Plan.night.windowStart - 1440, Plan.night.end - 1440), (Plan.nap.windowStart, Plan.nap.end)] {
            ctx.stroke(arc(a, b, r: R + w * 0.95), with: .color(Theme.gold), style: StrokeStyle(lineWidth: w * 0.45, lineCap: .round))
        }
        let nowM = Plan.dayClock(now)
        if nowM > nWake { ctx.stroke(arc(nWake, nowM, r: R - w * 1.05), with: .color(Theme.ivory.opacity(0.5)), lineWidth: w * 0.25) }
        for (m, t) in [((nOn + nWake) / 2, "night"), ((Plan.nap.onset + Plan.nap.wake) / 2, "nap")] {
            let a = CGFloat(ang(m).radians)
            ctx.draw(Text(t).font(.system(size: S * 0.036)).foregroundColor(Theme.sage), at: CGPoint(x: c.x + cos(a) * (R - w * 2.5), y: c.y + sin(a) * (R - w * 2.5)))
        }
        let a = CGFloat(ang(nowM).radians), p = CGPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R)
        let dot = Path(ellipseIn: CGRect(x: p.x - w * 1.05, y: p.y - w * 1.05, width: w * 2.1, height: w * 2.1))
        ctx.fill(dot, with: .color(.black)); ctx.stroke(dot, with: .color(Theme.ivory), lineWidth: w * 0.35)
        let hhmm = Plan.fmt(nowM)
        ctx.draw(Text(hhmm).font(Theme.serif(S * 0.17)).foregroundColor(Theme.ivory), at: CGPoint(x: c.x, y: c.y - S * 0.02))
        ctx.draw(Text(subline(nowM)).font(.system(size: S * 0.036)).kerning(2).foregroundColor(Theme.muted), at: CGPoint(x: c.x, y: c.y + S * 0.09))
        
    }

    private func subline(_ m: Double) -> String {
        let toNap = Int(Plan.nap.onset - m)
        if toNap > 0 && toNap < 360 { return String(format: "NAP IN %dH %02dM", toNap / 60, toNap % 60) }
        let toNight = Int((Plan.night.onset - 1440 + 1440 - m).truncatingRemainder(dividingBy: 1440))
        return String(format: "SLEEP IN %dH %02dM", toNight / 60, toNight % 60)
    }
}

// MARK: - Plan

struct PlanView: View {
    @ObservedObject private var nights = NightStore.shared
    private let planned: Double = (Plan.night.end - Plan.night.onset) + (Plan.nap.end - Plan.nap.onset)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Sleep plan")
                    Text("Biphasic · \(hm(planned))").font(Theme.serif(26)).foregroundStyle(Theme.ivory)
                }
                rhythm
                Card {
                    let s = AlarmSettings.load().clamped()
                    Eyebrow(text: "Nap cycle")
                    Text("around \(Plan.fmt(Plan.nap.onset))").font(Theme.serif(22)).foregroundStyle(Theme.ivory)
                    row("Wakes you", "\(Int(s.napEarliest))–\(Int(s.napLatest)) min after you fall asleep")
                    row("Earlier", "as soon as the cycle ends")
                    row("Sleep found", "\(Plan.fmt(Plan.nap.onset - 60))–\(Plan.fmt(Plan.nap.onset + 90)), or \"Nap now\"")
                }
                Card {
                    Eyebrow(text: "Night")
                    Text("\(Plan.fmt(Plan.night.onset)) → \(Plan.fmt(Plan.night.end))").font(Theme.serif(22)).foregroundStyle(Theme.ivory)
                    row("Cycles", "\(Plan.night.nCycles)")
                    row("Awake by", Plan.fmt(Plan.night.end))
                    row("Smart wake in light sleep", "last \(Int(Plan.night.end - Plan.night.windowStart)) min")
                    row("Wind-down", "from 22:30")
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
    }
    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a).font(.subheadline).foregroundStyle(Theme.ivory); Spacer(); Text(b).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.trailing) }.padding(.top, 4)
    }

    /// your measured cycle and what it means for bedtime
    @ViewBuilder private var rhythm: some View {
        if let avg = nights.averageCycle {
            Card {
                Eyebrow(text: "Your rhythm")
                Text("\(Int(avg.rounded()))-minute cycles").font(Theme.serif(22)).foregroundStyle(Theme.ivory)
                row("Measured over", "\(nights.nightsWithCycles) night\(nights.nightsWithCycles == 1 ? "" : "s")")
                ForEach([4, 3], id: \.self) { n in
                    row("\(n) full cycles by \(Plan.fmt(Plan.night.end))", "asleep by \(Plan.fmt(Plan.night.end - Double(n) * avg))")
                }
                Text("Falling asleep takes a while: be in bed a bit before.").font(.caption).foregroundStyle(Theme.muted).padding(.top, 4)
            }
        }
    }
}

// MARK: - Faces: the watch face live, plus every mode

struct FacesView: View {
    @EnvironmentObject private var health: HealthStore
    @State private var preview: FaceMode? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Watch face")
                FacePreview(mode: preview).padding(.horizontal, 40)
                Card {
                    ForEach(FaceMode.allCases, id: \.self) { m in modeRow(m) }
                }
                LampsCard()
                AudioCard()
            }
            .padding(16)
        }
        .background(Theme.bg)
    }

    private func modeRow(_ m: FaceMode) -> some View {
                        Button { preview = preview == m ? nil : m } label: {
                            HStack {
                                Text(m.rawValue.capitalized).foregroundStyle(Theme.ivory)
                                Spacer()
                                if preview == m { Text("PREVIEW").font(.caption2).kerning(1.5).foregroundStyle(Theme.sage) }
                            }.padding(.vertical, 6)
                        }
    }
}

struct FacePreview: View {
    @EnvironmentObject private var health: HealthStore
    let mode: FaceMode?
    private let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            Canvas { ctx, size in draw(&ctx, size, tl.date) }
        }
        .aspectRatio(696.0 / 830.0, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.stroke(Color(hex: 0x1D1D1D), lineWidth: 6))
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ date: Date) {
        let state = FaceState(date: date, mode: mode ?? FaceMode.auto(date))
        FaceRenderer.draw(&ctx, size: size, state: state)
    }
}
