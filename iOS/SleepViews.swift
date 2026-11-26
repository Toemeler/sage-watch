import SwiftUI
import Charts

// MARK: - colours and small helpers

extension SleepStage {
    var color: Color {
        switch self {
        case .awake: return Color(hex: 0xC98F7A)
        case .rem: return Theme.rem
        case .light: return Theme.sage
        case .deep: return Color(hex: 0xCFE0C4)
        }
    }
}

extension ActivityKind {
    var color: Color {
        switch self {
        case .stationary: return Theme.sageDark
        case .walking: return Theme.sage
        case .running: return Theme.gold
        case .cycling: return Color(hex: 0xD9B98B)
        case .automotive: return Theme.rem
        case .unknown: return Theme.hair
        }
    }
}

func clock(_ t: Double) -> String { Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened) }
func dayName(_ t: Double) -> String { Date(timeIntervalSince1970: t).formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) }

struct StageRun: Identifiable {
    let id: Int
    let start: Date
    let end: Date
    let stage: SleepStage
}

extension NightAnalysis {
    /// consecutive epochs of one stage inside the sleep window
    var runs: [StageRun] {
        var out: [StageRun] = []
        var current: (Int, SleepStage)? = nil
        func close(_ end: Int) {
            guard let c = current else { return }
            out.append(StageRun(id: out.count, start: Date(timeIntervalSince1970: max(time(ofEpoch: c.0), onset)),
                                end: Date(timeIntervalSince1970: min(time(ofEpoch: end), wake)), stage: c.1))
        }
        for k in 0..<epochCount {
            let t = time(ofEpoch: k)
            guard t + Params.epoch > onset && t < wake else { if current != nil { close(k); current = nil }; continue }
            if current?.1 != stage[k] { close(k); current = (k, stage[k]) }
        }
        close(epochCount)
        return out
    }

    /// (time, value) medians of `values` over blocks of `epochs` epochs inside [from, to)
    func blocks(_ values: [Double], epochs: Int, from: Double, to: Double) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        var k = 0
        while k < epochCount {
            let t = time(ofEpoch: k)
            if t >= from && t < to {
                let v = values[k..<min(epochCount, k + epochs)].filter { !$0.isNaN }
                if !v.isEmpty { out.append((Date(timeIntervalSince1970: t + Double(epochs) * Params.epoch / 2), Stats.median(Array(v)))) }
            }
            k += epochs
        }
        return out
    }
}

extension SleepHealth.Sample {
    var stage: SleepStage? {
        switch value {
        case "awake": return .awake
        case "rem": return .rem
        case "deep": return .deep
        case "core", "asleep": return .light
        default: return nil
        }
    }
}

// MARK: - Sleep tab

struct SleepView: View {
    @ObservedObject private var store = NightStore.shared

    var body: some View {
        NavigationStack {
            List {
                if let last = store.records.first {
                    Section {
                        NavigationLink { NightDetailView(record: last) } label: { LatestSleepCard(record: last) }
                            .listRowBackground(Theme.card)
                    } header: {
                        Text(last.kind == .nap ? "Last nap" : "Last night")
                    }
                }
                if let avg = store.averageCycle {
                    Section {
                        HStack {
                            Text("Your sleep cycle").foregroundStyle(Theme.ivory)
                            Spacer()
                            Text("\(Int(avg.rounded())) min").font(Theme.serif(20)).foregroundStyle(Theme.ivory)
                        }
                    } footer: {
                        Text("Average full cycle over \(store.nightsWithCycles) night\(store.nightsWithCycles == 1 ? "" : "s"). It gets more exact with every night.")
                    }
                }
                Section("Recent") {
                    if store.records.isEmpty {
                        Text(store.busy ? "Analysing…" : (store.note ?? "Pull down to analyse the watch's recordings."))
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    ForEach(store.records.dropFirst()) { r in
                        NavigationLink { NightDetailView(record: r) } label: { SleepRow(record: r) }
                    }
                }
            }
            .navigationTitle("Sleep")
            .refreshable { store.refresh() }
            .onAppear { store.refresh() }
            .overlay(alignment: .top) {
                if store.busy && !store.records.isEmpty { ProgressView().padding(.top, 4) }
            }
        }
    }
}

struct LatestSleepCard: View {
    let record: NightStore.Record
    var body: some View {
        let a = record.analysis
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "\(dayName(a.onset)) · \(clock(a.onset)) → \(clock(a.wake))")
            Text(hm(a.summary.asleepMinutes)).font(Theme.serif(40)).foregroundStyle(Theme.ivory)
            StageStrip(runs: a.runs).frame(height: 70)
            Text(cycleLine(a)).font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 6)
    }
}

struct SleepRow: View {
    let record: NightStore.Record
    var body: some View {
        let a = record.analysis
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.kind == .nap ? "Nap" : "Night") · \(dayName(a.onset))").foregroundStyle(Theme.ivory)
                Text("\(clock(a.onset)) → \(clock(a.wake)) · \(cycleLine(a))").font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(hm(a.summary.asleepMinutes)).font(Theme.serif(18)).foregroundStyle(Theme.ivory)
        }
    }
}

func cycleLine(_ a: NightAnalysis) -> String {
    let full = a.completeCycles
    guard !full.isEmpty else { return a.cycles.isEmpty ? "no cycle found" : "part of a cycle" }
    let avg = Int((full.map(\.minutes).reduce(0, +) / Double(full.count)).rounded())
    return "\(full.count) cycle\(full.count == 1 ? "" : "s") · average \(avg) min"
}

// MARK: - one sleep

struct NightDetailView: View {
    let record: NightStore.Record

    var body: some View {
        let a = record.analysis
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "\(record.kind == .nap ? "Nap" : "Night") · \(dayName(a.onset))")
                    Text("\(clock(a.onset)) → \(clock(a.wake))").font(Theme.serif(30)).foregroundStyle(Theme.ivory)
                    Text(sourceLine).font(.footnote).foregroundStyle(Theme.muted)
                }
                tiles(a)
                Card {
                    Eyebrow(text: "Stages (estimate) and cycles")
                    StageStrip(runs: a.runs, cycles: a.cycles).frame(height: 110)
                    if !appleRuns.isEmpty {
                        Eyebrow(text: "Apple Health").padding(.top, 6)
                        StageStrip(runs: appleRuns).frame(height: 90)
                    }
                }
                Card {
                    Eyebrow(text: "Heart rate · 5-min median")
                    LineChart(points: a.blocks(a.heart, epochs: 10, from: a.onset, to: a.wake), unit: "bpm", color: Color(hex: 0xC98F7A))
                        .frame(height: 130)
                }
                Card {
                    Eyebrow(text: "Breathing · per minute")
                    LineChart(points: a.blocks(a.breaths, epochs: 10, from: a.onset, to: a.wake), unit: "/min", color: Theme.sage)
                        .frame(height: 110)
                    Text("From the wrist's micro-motion while the arm lies still.").font(.caption2).foregroundStyle(Theme.muted)
                }
                Card {
                    Eyebrow(text: "Movement · seconds per 2 min")
                    MovementChart(analysis: a).frame(height: 80)
                }
                Card {
                    Eyebrow(text: "Cycles")
                    CycleChart(cycles: a.cycles).frame(height: CGFloat(max(1, a.cycles.count)) * 34 + 30)
                    ForEach(Array(a.cycles.enumerated()), id: \.offset) { i, c in
                        HStack {
                            Text(c.complete ? "Cycle \(i + 1)" : "Last part").foregroundStyle(Theme.ivory)
                            Spacer()
                            Text("\(clock(c.start)) → \(clock(c.end)) · \(Int(c.minutes.rounded())) min").foregroundStyle(Theme.muted)
                        }.font(.footnote)
                    }
                }
                if !alarmLines.isEmpty {
                    Card {
                        Eyebrow(text: "Alarm")
                        ForEach(alarmLines, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.ivory) }
                    }
                }
                Text("Stages are estimated from stillness, heart rate and breathing regularity at the wrist, not measured like in a sleep lab. Sleep times, heart rate and breathing are measured.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sourceLine: String {
        switch record.source {
        case "health": return "Fell asleep and woke: Apple Health"
        case "alarm": return "Woke with the alarm; fell asleep: detected by Sage"
        default: return "Fell asleep and woke: detected by Sage"
        }
    }

    private var appleRuns: [StageRun] {
        record.health.compactMap { s -> (SleepStage, SleepHealth.Sample)? in
            guard let st = s.stage else { return nil }
            return (st, s)
        }.enumerated().map { i, p in
            StageRun(id: i, start: Date(timeIntervalSince1970: p.1.start), end: Date(timeIntervalSince1970: p.1.end), stage: p.0)
        }
    }

    private var alarmLines: [String] {
        record.events.compactMap { e in
            switch e.event {
            case AlarmEvent.asleep.rawValue: return "\(clock(e.t)) fell asleep (live detection)"
            case AlarmEvent.windowOpen.rawValue: return "\(clock(e.t)) wake window opened"
            case AlarmEvent.ring.rawValue: return "\(clock(e.t)) alarm started (\(e.detail.replacingOccurrences(of: "night ", with: "").replacingOccurrences(of: "nap ", with: "")))"
            case AlarmEvent.stop.rawValue: return "\(clock(e.t)) stopped by \(e.detail)"
            default: return nil
            }
        }
    }

    private func tiles(_ a: NightAnalysis) -> some View {
        let s = a.summary
        let total = max(1, s.minutes)
        let full = a.completeCycles
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            tile("Asleep", hm(s.asleepMinutes), "\(clock(a.onset)) → \(clock(a.wake))")
            tile("Cycles", "\(full.count)\(a.cycles.count > full.count ? " + part" : "")",
                 full.isEmpty ? "–" : "average \(Int((full.map(\.minutes).reduce(0, +) / Double(full.count)).rounded())) min")
            tile("Deep-like", "\(Int(s.stages[3].rounded())) min", "\(Int((s.stages[3] / total * 100).rounded())) %")
            tile("REM-like", "\(Int(s.stages[1].rounded())) min", "\(Int((s.stages[1] / total * 100).rounded())) %")
            tile("Heart", s.hrMean.map { "\(Int($0.rounded())) avg" } ?? "–",
                 s.hrLow5.map { low in "low \(Int(low.rounded()))" + (s.hrLow5At.map { " at \(clock($0))" } ?? "") } ?? "")
            tile("Breathing", s.breaths.map { String(format: "%.1f / min", $0) } ?? "–", "\(s.bursts) movement bursts")
        }
    }

    private func tile(_ title: String, _ value: String, _ sub: String) -> some View {
        Card {
            Eyebrow(text: title)
            Text(value).font(Theme.serif(22)).foregroundStyle(Theme.ivory).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

// MARK: - charts

struct StageStrip: View {
    let runs: [StageRun]
    var cycles: [NightAnalysis.Cycle] = []

    var body: some View {
        Chart {
            ForEach(runs) { r in
                RectangleMark(xStart: .value("Start", r.start), xEnd: .value("End", r.end), y: .value("Stage", r.stage.name))
                    .foregroundStyle(r.stage.color)
            }
            ForEach(Array(cycles.dropLast().enumerated()), id: \.offset) { _, c in
                RuleMark(x: .value("Cycle end", Date(timeIntervalSince1970: c.end)))
                    .foregroundStyle(Theme.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: ["Awake", "REM", "Light", "Deep"])
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine().foregroundStyle(Theme.hair)
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.muted) }
        }
    }
}

struct LineChart: View {
    let points: [(Date, Double)]
    let unit: String
    let color: Color

    var body: some View {
        if points.isEmpty {
            Text("No data").font(.footnote).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let lo = points.map(\.1).min() ?? 0, hi = points.map(\.1).max() ?? 1
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", p.0), y: .value(unit, p.1))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: (lo - 2)...(hi + 2))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { _ in
                    AxisGridLine().foregroundStyle(Theme.hair)
                    AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.muted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.hair)
                    AxisValueLabel().foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

struct MovementChart: View {
    let analysis: NightAnalysis

    private var bars: [(Date, Int)] {
        let a = analysis
        var out: [(Date, Int)] = []
        var k = 0
        while k < a.epochCount {
            let t = a.time(ofEpoch: k)
            if t >= a.onset && t < a.wake {
                let v = a.movingSeconds[k..<min(a.epochCount, k + 4)].reduce(0, +)
                out.append((Date(timeIntervalSince1970: t + 60), v))
            }
            k += 4
        }
        return out
    }

    var body: some View {
        Chart {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, b in
                BarMark(x: .value("Time", b.0), y: .value("Seconds", b.1))
                    .foregroundStyle(Theme.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Theme.muted) }
        }
        .chartYAxis(.hidden)
    }
}

struct CycleChart: View {
    let cycles: [NightAnalysis.Cycle]

    private struct Part: Identifiable {
        let id: Int
        let cycle: String
        let stage: String
        let minutes: Double
    }

    private var parts: [Part] {
        var out: [Part] = []
        for (i, c) in cycles.enumerated() {
            let name = c.complete ? "Cycle \(i + 1)" : "Last part"
            for s in [SleepStage.deep, .light, .rem, .awake] where c.stages[s.rawValue] > 0 {
                out.append(Part(id: out.count, cycle: name, stage: s.name, minutes: c.stages[s.rawValue]))
            }
        }
        return out
    }

    var body: some View {
        Chart(parts) { p in
            BarMark(x: .value("Minutes", p.minutes), y: .value("Cycle", p.cycle))
                .foregroundStyle(by: .value("Stage", p.stage))
        }
        .chartForegroundStyleScale(["Deep": SleepStage.deep.color, "Light": SleepStage.light.color,
                                    "REM": SleepStage.rem.color, "Awake": SleepStage.awake.color])
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.muted) } }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.ivory) } }
    }
}
