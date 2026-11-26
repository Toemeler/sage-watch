import Foundation
import WatchConnectivity

/// Loads time ranges of the watch's recordings on the iPhone.
struct RecordingLibrary {
    let store = RecordingStore(root: Receiver.root)

    func seconds(_ lo: Double, _ hi: Double) -> SecondSeries {
        let c = store.numbers(RecordingFormat.summaryPrefix, columns: [0, 3, 4, 5, 6], from: lo, to: hi)
        guard c.count == 5 else { return SecondSeries() }
        return SecondSeries(t: c[0], sd: c[1], gx: c[2], gy: c[3], gz: c[4])
    }

    func heart(_ lo: Double, _ hi: Double) -> HeartSeries {
        let c = store.numbers(RecordingFormat.heartPrefix, columns: [0, 2], from: lo, to: hi)
        guard c.count == 2 else { return HeartSeries() }
        return HeartSeries(t: c[0], bpm: c[1])
    }

    /// raw motion on the 10 Hz grid, built chunk by chunk; nil without raw data
    func grid(_ lo: Double, _ hi: Double) -> Grid10? {
        var b = Grid10Builder(from: lo, to: hi)
        store.forEachChunk(RecordingFormat.rawPrefix, columns: [0, 1, 2, 3], from: lo, to: hi) { c in
            b.add(t: c[0], x: c[1], y: c[2], z: c[3])
        }
        return b.isEmpty ? nil : b.finish()
    }

    /// minutes of status lines that say the watch was on the charger (off the wrist)
    func charging(_ lo: Double, _ hi: Double) -> [Double] {
        store.rows(RecordingFormat.statusPrefix, from: lo, to: hi).compactMap { r in
            r.count > 2 && (r[2] == "charging" || r[2] == "full") ? Double(r[0]) : nil
        }
    }

    func battery(_ lo: Double, _ hi: Double) -> [(t: Double, level: Double, charging: Bool)] {
        store.rows(RecordingFormat.statusPrefix, from: lo, to: hi).compactMap { r in
            guard r.count > 2, let t = Double(r[0]), let b = Double(r[1]), b >= 0 else { return nil }
            return (t, b, r[2] == "charging" || r[2] == "full")
        }
    }

    struct Event: Codable, Hashable {
        var t: Double
        var event: String
        var detail: String
    }

    func events(_ lo: Double, _ hi: Double) -> [Event] {
        store.rows(RecordingFormat.eventsPrefix, from: lo, to: hi).compactMap { r in
            guard r.count >= 2, let t = Double(r[0]) else { return nil }
            return Event(t: t, event: r[1], detail: r.count > 2 ? r[2...].joined(separator: ",") : "")
        }
    }

    func activities(_ lo: Double, _ hi: Double) -> [(t: Double, kind: ActivityKind, confidence: Int)] {
        store.rows(RecordingFormat.activityPrefix, from: lo, to: hi).compactMap { r in
            guard r.count >= 3, let t = Double(r[0]), let k = ActivityKind(rawValue: r[1]) else { return nil }
            return (t, k, Int(r[2]) ?? 0)
        }
    }
}

/// Every sleep (nights and naps) of the last two weeks, analysed, cached and kept up to date.
@MainActor
final class NightStore: ObservableObject {
    static let shared = NightStore()

    enum Kind: String, Codable { case night, nap }

    struct Record: Identifiable, Codable {
        var id: String
        var kind: Kind
        var analysis: NightAnalysis
        /// where the sleep window came from: "health" (Apple Health), "alarm" (wake = the alarm) or "sage"
        var source: String
        var health: [SleepHealth.Sample]
        var events: [RecordingLibrary.Event]
        var version: Int
        var analysedAt: Double
    }

    /// bump when NightAnalysis or the rules here change: cached results are redone
    nonisolated static let version = 1

    @Published private(set) var records: [Record] = []
    @Published private(set) var busy = false
    @Published private(set) var note: String?

    private var refreshing: Task<Void, Never>?

    /// the newest night
    var lastNight: Record? { records.first { $0.kind == .night } }
    var lastNap: Record? { records.first { $0.kind == .nap } }

    /// your average full cycle over the nights on record (nil until there is one)
    var averageCycle: Double? {
        let all = records.filter { $0.kind == .night }.flatMap { $0.analysis.completeCycles.filter { $0.end != $0.start } }.map(\.minutes)
        return all.isEmpty ? nil : all.reduce(0, +) / Double(all.count)
    }

    var nightsWithCycles: Int { records.filter { $0.kind == .night && !$0.analysis.completeCycles.isEmpty }.count }

    private static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Nights", isDirectory: true)
    }

    init() {
        records = Self.loadCache()
    }

    func refresh(days: Int = 14) {
        guard refreshing == nil else { return }
        busy = true
        refreshing = Task {
            await SleepHealth.requestAccess()
            let now = Date().timeIntervalSince1970
            let lo = now - Double(days) * 86400
            // sleeps that ended well before the newest one are final: only the last day and a half is read again
            let newest = records.map(\.analysis.wake).max()
            let scanFrom = max(lo, (newest ?? lo) - 36 * 3600)
            let kept = records.filter { $0.analysis.wake < scanFrom && $0.analysis.onset >= lo }
            let health = await SleepHealth.samples(from: Date(timeIntervalSince1970: scanFrom - 86400), to: Date())
            let cached = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let result = await Task.detached(priority: .userInitiated) {
                Self.analyse(from: scanFrom, to: now, health: health, cached: cached)
            }.value
            let fresh = result.records.filter { r in !kept.contains { $0.analysis.wake > r.analysis.onset && r.analysis.wake > $0.analysis.onset } }
            records = (fresh + kept).sorted { $0.analysis.onset > $1.analysis.onset }
            note = records.isEmpty ? result.note : nil
            busy = false
            refreshing = nil
            Self.saveCache(records)
            WatchSync.shared.sendLastSleep(lastNight)
        }
    }

    // MARK: work (off the main thread)

    nonisolated private static func analyse(from lo: Double, to now: Double, health: [SleepHealth.Sample],
                                            cached: [String: Record]) -> (records: [Record], note: String?) {
        let lib = RecordingLibrary()
        let sec = lib.seconds(lo, now)
        guard sec.count > 0 else { return ([], "No motion data from the watch yet.") }
        let charging = lib.charging(lo, now)
        let heartAll = lib.heart(lo - 3600, now)
        let events = lib.events(lo - 86400, now)

        var periods = NightAnalysis.sleepPeriods(seconds: sec, charging: charging, from: lo, to: now, minMinutes: 20)
        // a nap must look like sleep: the heart rate settles (not above the half hour before)
        periods = periods.filter { p in
            let len = p.wake - p.onset
            if len >= 60 * 60 { return true }
            let before = slice(heartAll, p.onset - 1800, p.onset).bpm
            let during = slice(heartAll, p.onset, min(p.wake, p.onset + 1200)).bpm
            if before.count < 10 || during.count < 10 { return true }
            return Stats.median(during) <= Stats.median(before) + 1
        }

        var out: [Record] = []
        var taken: [(Double, Double)] = []
        for p in periods.reversed() {                                   // newest first
            let kind = classify(p.onset, p.wake)
            if kind == .night && p.wake - p.onset < 60 * 60 { continue }
            // the sleep window: Apple Health's when it covers this sleep, else the alarm's ring as the wake, else Sage's
            var onset = p.onset, wake = p.wake, source = "sage"
            if let span = SleepHealth.asleepSpan(health, around: p.onset, p.wake) {
                onset = span.onset; wake = span.wake; source = "health"
            } else if let ring = events.last(where: { $0.event == AlarmEvent.ring.rawValue && $0.t >= p.wake - 45 * 60 && $0.t <= p.wake + 45 * 60 && $0.t > p.onset }) {
                wake = ring.t; source = "alarm"
            }
            if let asleep = events.last(where: { $0.event == AlarmEvent.asleep.rawValue && abs($0.t - p.onset) < 20 * 60 }), source == "sage" {
                onset = asleep.t          // the watch's live detection, to the second
            }
            if taken.contains(where: { $0.0 < wake && onset < $0.1 }) { continue }   // already covered (Health joined two)
            taken.append((onset, wake))
            let id = "\(kind.rawValue)-\(Int((onset / 600).rounded()) * 600)"
            if let c = cached[id], c.version == version, c.analysedAt > wake + 3600, c.source == source {
                out.append(c)
                continue
            }
            let a0 = onset - 3600, a1 = min(wake + 3600, now)
            let analysis = NightAnalysis.analyze(seconds: slice(sec, a0, a1), heart: slice(heartAll, a0 - 600, a1 + 600),
                                                 grid: lib.grid(a0 - 60, a1 + 60), charging: charging.filter { $0 >= a0 - 120 && $0 < a1 + 120 },
                                                 from: a0, to: a1, onset: onset, wake: wake, minSleepEpochs: 40)
            guard let analysis else { continue }
            let hs = health.filter { $0.end > onset - 1800 && $0.start < wake + 1800 }
            let ev = events.filter { $0.t >= onset - 3 * 3600 && $0.t <= wake + 3600 }
            out.append(Record(id: id, kind: kind, analysis: analysis, source: source, health: hs, events: ev,
                              version: version, analysedAt: Date().timeIntervalSince1970))
        }
        return (out.sorted { $0.analysis.onset > $1.analysis.onset }, out.isEmpty ? "No sleep found in the last two weeks yet." : nil)
    }

    /// naps start between 11:00 and 21:00 and last under 3½ hours
    nonisolated static func classify(_ onset: Double, _ wake: Double) -> Kind {
        let h = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: onset))
        return (h >= 11 && h < 21 && wake - onset < 3.5 * 3600) ? .nap : .night
    }

    nonisolated static func slice(_ s: SecondSeries, _ lo: Double, _ hi: Double) -> SecondSeries {
        let a = lowerBound(s.t, lo), b = lowerBound(s.t, hi)
        return SecondSeries(t: Array(s.t[a..<b]), sd: Array(s.sd[a..<b]), gx: Array(s.gx[a..<b]), gy: Array(s.gy[a..<b]), gz: Array(s.gz[a..<b]))
    }

    nonisolated static func slice(_ h: HeartSeries, _ lo: Double, _ hi: Double) -> HeartSeries {
        let a = lowerBound(h.t, lo), b = lowerBound(h.t, hi)
        return HeartSeries(t: Array(h.t[a..<b]), bpm: Array(h.bpm[a..<b]))
    }

    nonisolated static func lowerBound(_ v: [Double], _ x: Double) -> Int {
        var lo = 0, hi = v.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if v[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: cache

    nonisolated private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    private static func saveCache(_ records: [Record]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        if let data = try? encoder().encode(records) { try? data.write(to: cacheRoot.appendingPathComponent("records.json"), options: .atomic) }
    }

    private static func loadCache() -> [Record] {
        guard let data = try? Data(contentsOf: cacheRoot.appendingPathComponent("records.json")),
              let r = try? decoder().decode([Record].self, from: data) else { return [] }
        return r.filter { $0.version == version }
    }

    /// the records as JSON for exports (so analyses can be compared and tuned later)
    nonisolated static func exportJSON(_ records: [Record]) -> Data? {
        let e = encoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(records)
    }
}

/// The iPhone → watch application context. One dictionary carries everything, so every update sends all of it.
final class WatchSync {
    static let shared = WatchSync()
    static let lastSleepKey = "lastSleep"

    private var context: [String: Any] = [:]
    private let queue = DispatchQueue(label: "sage.watchsync")

    func sendSettings(_ s: AlarmSettings) {
        queue.async {
            self.context[AlarmLink.settingsKey] = s.dictionary
            self.push()
        }
    }

    func sendLastSleep(_ r: NightStore.Record?) {
        guard let r else { return }
        let a = r.analysis
        let full = a.completeCycles
        let summary = LastSleepSummary(onset: a.onset, wake: a.wake, asleepMinutes: a.summary.asleepMinutes, cycles: full.count,
                                       averageCycle: full.isEmpty ? nil : full.map(\.minutes).reduce(0, +) / Double(full.count))
        queue.async {
            self.context[Self.lastSleepKey] = summary.dictionary
            self.push()
        }
    }

    private func push() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        if context[AlarmLink.settingsKey] == nil { context[AlarmLink.settingsKey] = AlarmSettings.load().dictionary }
        try? s.updateApplicationContext(context)
    }
}
