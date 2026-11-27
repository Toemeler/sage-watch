import SwiftUI
import Charts

/// One day from the watch's recordings: what you were doing, heart rate, movement, battery, and your sleeps.
struct DayView: View {
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var data: DayData?
    @State private var loading = false
    @ObservedObject private var nights = NightStore.shared
    /// the chart open on the whole screen (tap a card)
    @State private var open: DayChart?

    enum DayChart: String, Identifiable {
        case activity, heart, movement, battery
        var id: String { rawValue }
        var title: String {
            switch self {
            case .activity: return "What you were doing"
            case .heart: return "Heart rate"
            case .movement: return "Movement"
            case .battery: return "Watch battery"
            }
        }
    }

    struct DayData {
        struct Span: Identifiable { let id: Int; let start: Date; let end: Date; let label: String; let color: Color }
        var activity: [Span] = []
        var activityMinutes: [(ActivityKind, Double)] = []
        var heart: [(Date, Double)] = []
        var movement: [(Date, Int)] = []
        var battery: [(Date, Double)] = []
        /// every heart sample and movement per minute, for the full-screen charts zoomed in
        var heartRaw: [(Double, Double)] = []
        var movement1: [(Double, Int)] = []
        var hasData: Bool { !heart.isEmpty || !movement.isEmpty || !battery.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    DatePicker("", selection: $day, in: ...Date(), displayedComponents: .date).labelsHidden()
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(Calendar.current.isDateInToday(day))
                }
                .tint(Theme.sage)
                if loading && data == nil { ProgressView().frame(maxWidth: .infinity) }
                if let d = data {
                    if !d.hasData {
                        Text("No watch data on this day.").font(.footnote).foregroundStyle(Theme.muted)
                    } else {
                        content(d)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle("Day")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: day) { await load() }
    }

    @ViewBuilder private func content(_ d: DayData) -> some View {
        let range = day...day.addingTimeInterval(86400)
        Card {
            header("What you were doing")
            activityChart(d, x: range).frame(height: 70)
            if !d.activityMinutes.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                    ForEach(d.activityMinutes.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            Circle().fill(d.activityMinutes[i].0.color).frame(width: 7, height: 7)
                            Text("\(d.activityMinutes[i].0.label) \(hm(d.activityMinutes[i].1))").font(.caption).foregroundStyle(Theme.ivory)
                        }
                    }
                }
            } else {
                Text("Activity is recorded from Sage 0.4.0 on.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .contentShape(Rectangle()).onTapGesture { open = .activity }
        Card {
            header("Heart rate · 5-min median")
            heartChart(d, x: range, y: nil).frame(height: 140)
        }
        .contentShape(Rectangle()).onTapGesture { open = .heart }
        Card {
            header("Movement · seconds per 5 min")
            movementChart(d, x: range, y: nil).frame(height: 80)
        }
        .contentShape(Rectangle()).onTapGesture { open = .movement }
        Card {
            header("Watch battery")
            batteryChart(d, x: range, y: 0...100).frame(height: 90)
        }
        .contentShape(Rectangle()).onTapGesture { open = .battery }
        .fullScreenCover(item: $open) { kind in fullScreen(kind, d, range) }
    }

    /// a card's title with the sign that it opens on the whole screen
    private func header(_ text: String) -> some View {
        HStack {
            Eyebrow(text: text)
            Spacer()
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(Theme.muted)
                .accessibilityLabel(Text("Open full screen"))
        }
    }

    @ViewBuilder private func fullScreen(_ kind: DayChart, _ d: DayData, _ range: ClosedRange<Date>) -> some View {
        switch kind {
        case .activity:
            ZoomChartScreen(title: kind.title, fullX: range, fullY: nil, minSpanY: 1) { x, _ in activityChart(d, x: x) }
        case .heart:
            ZoomChartScreen(title: kind.title, fullX: range, fullY: heartRange(d), minSpanY: 10) { x, y in heartChart(d, x: x, y: y) }
        case .movement:
            ZoomChartScreen(title: kind.title, fullX: range, fullY: 0...300, minSpanY: 10) { x, y in movementChart(d, x: x, y: y) }
        case .battery:
            ZoomChartScreen(title: kind.title, fullX: range, fullY: 0...100, minSpanY: 5) { x, y in batteryChart(d, x: x, y: y) }
        }
    }

    private func heartRange(_ d: DayData) -> ClosedRange<Double> {
        let vals: [Double] = d.heartRaw.map { $0.1 }
        let lo: Double = max(0, (vals.min() ?? 40) - 5), hi: Double = (vals.max() ?? 120) + 5
        return lo...hi
    }

    // MARK: the charts, for a card and for the full screen (x and y: the visible ranges)

    private func activityChart(_ d: DayData, x: ClosedRange<Date>) -> some View {
        Chart {
            ForEach(d.activity) { s in
                RectangleMark(xStart: .value("Start", s.start), xEnd: .value("End", s.end), y: .value("Row", "Activity"))
                    .foregroundStyle(s.color)
            }
            ForEach(sleeps) { s in
                RectangleMark(xStart: .value("Start", s.start), xEnd: .value("End", s.end), y: .value("Row", "Sleep"))
                    .foregroundStyle(Theme.rem)
            }
        }
        .chartXScale(domain: x)
        .chartXAxis { timeAxis(x) }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.muted) } }
    }

    /// zoomed in below 3 h: every heart sample (up to ~900 drawn); else the 5-min medians
    private func heartChart(_ d: DayData, x: ClosedRange<Date>, y: ClosedRange<Double>?) -> some View {
        let span = x.upperBound.timeIntervalSince(x.lowerBound)
        let xs = x.lowerBound.timeIntervalSince1970...x.upperBound.timeIntervalSince1970
        let pts: [(Date, Double)] = span < 3 * 3600
            ? ChartZoom.thin(d.heartRaw, in: xs).map { (Date(timeIntervalSince1970: $0.0), $0.1) }
            : d.heart
        let values: [Double] = pts.map { $0.1 }
        let lo: Double = (values.min() ?? 40) - 5, hi: Double = (values.max() ?? 120) + 5
        let yDomain: ClosedRange<Double> = y ?? lo...hi
        return Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.0), y: .value("bpm", p.1)).foregroundStyle(Color(hex: 0xC98F7A))
            }
        }
        .chartXScale(domain: x)
        .chartYScale(domain: yDomain)
        .chartXAxis { timeAxis(x) }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Theme.hair); AxisValueLabel().foregroundStyle(Theme.muted) } }
        .clipped()
    }

    /// zoomed in below 3 h: seconds moving per minute; else per 5 min
    private func movementChart(_ d: DayData, x: ClosedRange<Date>, y: ClosedRange<Double>?) -> some View {
        let span = x.upperBound.timeIntervalSince(x.lowerBound)
        let xs = x.lowerBound.timeIntervalSince1970...x.upperBound.timeIntervalSince1970
        let fine = span < 3 * 3600
        let pts: [(Date, Int)] = fine
            ? ChartZoom.thin(d.movement1, in: xs).map { (Date(timeIntervalSince1970: $0.0), $0.1) }
            : d.movement
        let top: Double = Double(max(10, pts.map { $0.1 }.max() ?? 10))
        let yDomain: ClosedRange<Double> = y ?? 0...top
        return Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                BarMark(x: .value("Time", p.0), y: .value("Seconds", p.1)).foregroundStyle(Theme.muted)
            }
        }
        .chartXScale(domain: x)
        .chartYScale(domain: yDomain)
        .chartXAxis { timeAxis(x) }
        .chartYAxis(y == nil ? .hidden : .automatic)
        .clipped()
    }

    private func batteryChart(_ d: DayData, x: ClosedRange<Date>, y: ClosedRange<Double>) -> some View {
        Chart {
            ForEach(Array(d.battery.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.0), y: .value("%", p.1 * 100)).foregroundStyle(Theme.gold)
            }
        }
        .chartXScale(domain: x)
        .chartYScale(domain: y)
        .chartXAxis { timeAxis(x) }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Theme.hair); AxisValueLabel().foregroundStyle(Theme.muted) } }
        .clipped()
    }

    /// hour marks that suit the visible span: every 6 h for the day, finer when zoomed in
    private func timeAxis(_ x: ClosedRange<Date>) -> some AxisContent {
        let span = x.upperBound.timeIntervalSince(x.lowerBound)
        let step: Calendar.Component = span > 4 * 3600 ? .hour : .minute
        let count = span > 12 * 3600 ? 6 : span > 4 * 3600 ? 1 : span > 3600 ? 15 : span > 1200 ? 5 : 1
        return AxisMarks(values: .stride(by: step, count: count)) { _ in
            AxisGridLine().foregroundStyle(Theme.hair)
            AxisValueLabel(format: span > 4 * 3600 ? .dateTime.hour() : .dateTime.hour().minute()).foregroundStyle(Theme.muted)
        }
    }

    private struct SleepSpan: Identifiable { let id: String; let start: Date; let end: Date }

    private var sleeps: [SleepSpan] {
        let lo = day.timeIntervalSince1970, hi = lo + 86400
        return nights.records.filter { $0.analysis.wake > lo && $0.analysis.onset < hi }.map {
            SleepSpan(id: $0.id, start: Date(timeIntervalSince1970: max($0.analysis.onset, lo)), end: Date(timeIntervalSince1970: min($0.analysis.wake, hi)))
        }
    }

    private func shift(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: day), d <= Date() { day = d }
    }

    private func load() async {
        loading = true
        let lo = day.timeIntervalSince1970, hi = lo + 86400
        let now = Date().timeIntervalSince1970
        let result = await Task.detached(priority: .userInitiated) { Self.read(lo, hi, now) }.value
        data = result
        loading = false
    }

    nonisolated private static func read(_ lo: Double, _ hi: Double, _ now: Double) -> DayData {
        let lib = RecordingLibrary()
        var d = DayData()
        let heart = lib.heart(lo, hi)
        d.heartRaw = zip(heart.t, heart.bpm).map { ($0, $1) }
        var t = lo
        while t < hi {
            let a = NightStore.lowerBound(heart.t, t), b = NightStore.lowerBound(heart.t, t + 300)
            if b > a { d.heart.append((Date(timeIntervalSince1970: t + 150), Stats.median(Array(heart.bpm[a..<b])))) }
            t += 300
        }
        let sec = lib.seconds(lo, hi)
        t = lo
        while t < hi {
            let a = NightStore.lowerBound(sec.t, t), b = NightStore.lowerBound(sec.t, t + 60)
            if b > a { d.movement1.append((t + 30, sec.sd[a..<b].filter { $0 > NightAnalysis.Params.moveSD }.count)) }
            t += 60
        }
        t = lo
        while t < hi {
            let a = NightStore.lowerBound(sec.t, t), b = NightStore.lowerBound(sec.t, t + 300)
            if b > a { d.movement.append((Date(timeIntervalSince1970: t + 150), sec.sd[a..<b].filter { $0 > NightAnalysis.Params.moveSD }.count)) }
            t += 300
        }
        d.battery = lib.battery(lo, hi).map { (Date(timeIntervalSince1970: $0.t), $0.level) }
        // activity: each line holds until the next one (the first one of the day starts with the line before it)
        let rows = lib.activities(lo - 12 * 3600, hi)
        let end = min(hi, now)
        var minutes: [ActivityKind: Double] = [:]
        for (i, r) in rows.enumerated() {
            let s = max(r.t, lo)
            let e = min(i + 1 < rows.count ? rows[i + 1].t : end, end)
            guard e > s, r.kind != .unknown else { continue }
            d.activity.append(.init(id: i, start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e), label: r.kind.label, color: r.kind.color))
            minutes[r.kind, default: 0] += (e - s) / 60
        }
        d.activityMinutes = ActivityKind.allCases.compactMap { k in minutes[k].map { (k, $0) } }.filter { $0.1 >= 1 }
        return d
    }
}
