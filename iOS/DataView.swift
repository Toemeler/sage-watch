import SwiftUI
import HealthKit

/// The recorder's data: what arrived from the watch, and an export cut to the last nap, the last night or any range.
struct DataView: View {
    @ObservedObject private var receiver = Receiver.shared
    @State private var range: ExportRange = .lastNight
    @State private var from = Date().addingTimeInterval(-6 * 3600)
    @State private var to = Date()
    @State private var busy = false
    @State private var status: String?
    @State private var exported: URL?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        BreathingView()
                    } label: {
                        Label("Live breathing", systemImage: "lungs")
                    }
                } footer: {
                    Text("Streams the watch's motion to this screen while it is open and shows your breathing.")
                }

                Section {
                    Picker("Range", selection: $range) {
                        ForEach(ExportRange.allCases) { r in Text(r.title).tag(r) }
                    }
                    if range == .custom {
                        DatePicker("From", selection: $from)
                        DatePicker("To", selection: $to)
                    } else {
                        let r = range.interval(now: Date())
                        Text("\(r.start.formatted(date: .abbreviated, time: .shortened)) → \(r.end.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Button(busy ? "Building…" : "Build export") { build() }
                        .disabled(busy)
                    if let url = exported {
                        ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                    }
                    if let status { Text(status).font(.footnote).foregroundStyle(Theme.muted) }
                } header: {
                    Text("Export")
                } footer: {
                    Text("A zip of CSV files: heart rate every ~5 s, motion per second, raw motion, air pressure and battery. Exports are also kept in the Files app under On My iPhone › Sage › Exports.")
                }

                Section {
                    if receiver.segments.isEmpty {
                        Text("Nothing yet. Long-press the face on the watch and turn on Record; files arrive every 30–60 minutes.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    ForEach(receiver.segments) { seg in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(seg.title).foregroundStyle(Theme.ivory)
                            Text(seg.detail).font(.caption).foregroundStyle(Theme.muted)
                        }
                        .swipeActions {
                            Button(role: .destructive) { receiver.delete(seg) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("From the watch")
                } footer: {
                    if let t = receiver.lastReceived {
                        Text("Last file \(t.formatted(date: .omitted, time: .shortened))")
                    }
                }

                Section {
                    Button("Start recording on the watch") { startOnWatch() }
                } footer: {
                    Text("Opens Sage on the watch and starts the recorder, for example after charging.")
                }
            }
            .navigationTitle("Data")
            .refreshable { receiver.reload() }
            .onAppear { receiver.reload() }
        }
    }

    private func build() {
        let r = range == .custom ? DateInterval(start: min(from, to), end: max(from, to)) : range.interval(now: Date())
        busy = true
        status = nil
        exported = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: (URL?, String)
            do {
                let result = try Exporter.export(from: r.start, to: r.end)
                let total = result.lines.values.reduce(0, +)
                outcome = (result.zip, "\(total.formatted()) lines · " + result.lines.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.formatted())" }.joined(separator: " · "))
            } catch {
                outcome = (nil, error.localizedDescription)
            }
            DispatchQueue.main.async {
                exported = outcome.0
                status = outcome.1
                busy = false
            }
        }
    }

    private func startOnWatch() {
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        HKHealthStore().startWatchApp(with: config) { ok, error in
            DispatchQueue.main.async {
                status = ok ? "Asked the watch to start recording." : "Could not reach the watch: \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }
}

/// Ranges built from the sleep plan, with room before and after each block.
enum ExportRange: String, CaseIterable, Identifiable {
    case lastNap, lastNight, last24h, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastNap: return "Last nap"
        case .lastNight: return "Last night"
        case .last24h: return "Last 24 hours"
        case .custom: return "Custom"
        }
    }

    func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .lastNap:
            // 16:00 – 19:30 around the 17:00 nap
            let start = Self.latest(Plan.nap.onset, now: now, calendar: calendar)
            return DateInterval(start: start.addingTimeInterval(-3600), end: start.addingTimeInterval(9000))
        case .lastNight:
            // 21:30 – 09:00 around the 00:30 night
            let start = Self.latest(Plan.night.onset, now: now, calendar: calendar)
            return DateInterval(start: start.addingTimeInterval(-3 * 3600), end: start.addingTimeInterval(8.5 * 3600))
        case .last24h, .custom:
            return DateInterval(start: now.addingTimeInterval(-24 * 3600), end: now)
        }
    }

    /// the latest moment `minutes` after some midnight that is not in the future (night minutes count 24+ from the evening's day)
    static func latest(_ minutes: Double, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        var best = Date.distantPast
        for offset in -2...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let t = calendar.date(byAdding: .second, value: Int(minutes * 60), to: day) else { continue }
            if t <= now && t > best { best = t }
        }
        return best
    }
}
