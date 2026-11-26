import SwiftUI
import Charts

/// One day from the watch's recordings: what you were doing, heart rate, movement, battery, and your sleeps.
struct DayView: View {
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var data: DayData?
    @State private var loading = false
    @ObservedObject private var nights = NightStore.shared

    struct DayData {
        struct Span: Identifiable { let id: Int; let start: Date; let end: Date; let label: String; let color: Color }
        var activity: [Span] = []
        var activityMinutes: [(ActivityKind, Double)] = []
        var heart: [(Date, Double)] = []
        var movement: [(Date, Int)] = []
        var battery: [(Date, Double)] = []
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
            Eyebrow(text: "What you were doing")
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
            .chartXScale(domain: range)
            .chartXAxis { hours }
            .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.muted) } }
            .frame(height: 70)
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
        Card {
            Eyebrow(text: "Heart rate · 5-min median")
            Chart {
                ForEach(Array(d.heart.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", p.0), y: .value("bpm", p.1)).foregroundStyle(Color(hex: 0xC98F7A))
                }
            }
            .chartXScale(domain: range)
            .chartXAxis { hours }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Theme.hair); AxisValueLabel().foregroundStyle(Theme.muted) } }
            .frame(height: 140)
        }
        Card {
            Eyebrow(text: "Movement · seconds per 5 min")
            Chart {
                ForEach(Array(d.movement.enumerated()), id: \.offset) { _, p in
                    BarMark(x: .value("Time", p.0), y: .value("Seconds", p.1)).foregroundStyle(Theme.muted)
                }
            }
            .chartXScale(domain: range)
            .chartXAxis { hours }
            .chartYAxis(.hidden)
            .frame(height: 80)
        }
        Card {
            Eyebrow(text: "Watch battery")
            Chart {
                ForEach(Array(d.battery.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", p.0), y: .value("%", p.1 * 100)).foregroundStyle(Theme.gold)
                }
            }
            .chartXScale(domain: range)
            .chartYScale(domain: 0...100)
            .chartXAxis { hours }
            .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) { _ in AxisGridLine().foregroundStyle(Theme.hair); AxisValueLabel().foregroundStyle(Theme.muted) } }
            .frame(height: 90)
        }
    }

    private var hours: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
            AxisGridLine().foregroundStyle(Theme.hair)
            AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.muted)
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
        var t = lo
        while t < hi {
            let a = NightStore.lowerBound(heart.t, t), b = NightStore.lowerBound(heart.t, t + 300)
            if b > a { d.heart.append((Date(timeIntervalSince1970: t + 150), Stats.median(Array(heart.bpm[a..<b])))) }
            t += 300
        }
        let sec = lib.seconds(lo, hi)
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
