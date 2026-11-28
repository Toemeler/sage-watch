import Foundation
import HealthKit
import WatchConnectivity

/// One live value from the watch's probe.
enum ProbeValue: Equatable {
    case number(Double)
    case text(String)

    var display: String {
        switch self {
        case .number(let v):
            let a = abs(v)
            if a >= 10_000 { return String(format: "%.0f", v) }
            if a >= 100 { return String(format: "%.1f", v) }
            if a >= 1 { return String(format: "%.2f", v) }
            return String(format: "%.4f", v)
        case .text(let s):
            return s
        }
    }

    var number: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
}

/// The iPhone side of the data lab: the watch probe's snapshots (once a second while the watch is near), their
/// history for charts, and a log of every snapshot on the iPhone (`Documents/ProbeLive/probe-live_<day>.jsonl`, also
/// in the Files app). The probe's files arrive separately, through `Receiver`, under Recordings/probe-….
final class ProbeStore: ObservableObject {
    static let shared = ProbeStore()

    @Published private(set) var latest: [String: ProbeValue] = [:]
    @Published private(set) var units: [String: String] = [:]
    @Published private(set) var lastSnapshot: Date?
    @Published private(set) var snapshots = 0
    @Published private(set) var wave: [Float] = []
    @Published private(set) var watchRunning: Bool?
    @Published private(set) var watchSince: Date?
    @Published var status: String?

    /// newest values per numeric key, for the charts (at most `historyLimit` each; one per second)
    private(set) var history: [String: [(Date, Double)]] = [:]
    static let historyLimit = 900

    static var logRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ProbeLive", isDirectory: true)
    }

    private let logQueue = DispatchQueue(label: "sage.probe.log", qos: .utility)
    private var logHandle: FileHandle?
    private var logDay = ""
    @Published private(set) var logFile: URL?
    @Published private(set) var logBytes: Int64 = 0

    /// groups in the order the Lab tab shows them
    static let groupOrder = ["watch", "hk", "motion", "batched", "air", "steps", "activity", "gps", "lines", "probe"]

    static func groupTitle(_ g: String) -> String {
        switch g {
        case "watch": return "Watch"
        case "hk": return "Health (newest sample)"
        case "motion": return "Motion 50 Hz"
        case "batched": return "High-rate sensors"
        case "air": return "Barometer and altitude"
        case "steps": return "Pedometer"
        case "activity": return "Activity"
        case "gps": return "Location and compass"
        case "lines": return "Lines recorded per stream"
        case "probe": return "Probe"
        default: return g
        }
    }

    /// main queue
    func receive(_ snapshot: [String: Any], wave data: Data?) {
        let now = Date()
        var next = latest
        var nextUnits = units
        for (key, raw) in snapshot {
            if key == "t" { continue }
            if key.hasPrefix("unit.") {
                if let s = raw as? String { nextUnits[String(key.dropFirst(5))] = s }
                continue
            }
            if let v = raw as? Double {
                next[key] = .number(v)
                appendHistory(key, now, v)
            } else if let v = raw as? Int {
                next[key] = .number(Double(v))
                appendHistory(key, now, Double(v))
            } else if let s = raw as? String {
                next[key] = .text(s)
            } else if let b = raw as? Bool {
                next[key] = .text(b ? "yes" : "no")
            }
        }
        latest = next
        units = nextUnits
        lastSnapshot = now
        snapshots += 1
        watchRunning = true
        if let data {
            var w = wave + ProbeLink.unpackWave(data)
            if w.count > 500 { w.removeFirst(w.count - 500) }
            wave = w
        }
        log(snapshot, at: now)
    }

    private func appendHistory(_ key: String, _ t: Date, _ v: Double) {
        var h = history[key] ?? []
        h.append((t, v))
        if h.count > Self.historyLimit { h.removeFirst(h.count - Self.historyLimit) }
        history[key] = h
    }

    /// keys of one group, sorted, without the group prefix shown twice
    func keys(in group: String) -> [String] {
        latest.keys.filter { Self.group(of: $0) == group }.sorted()
    }

    var groups: [String] {
        let present = Set(latest.keys.map { Self.group(of: $0) })
        let known = Self.groupOrder.filter { present.contains($0) }
        let other = present.subtracting(Self.groupOrder).sorted()
        return known + other
    }

    static func group(of key: String) -> String {
        guard let dot = key.firstIndex(of: ".") else { return "probe" }
        return String(key[key.startIndex..<dot])
    }

    static func label(of key: String) -> String {
        guard let dot = key.firstIndex(of: ".") else { return key }
        return String(key[key.index(after: dot)...])
    }

    // MARK: the iPhone's own log of every snapshot

    private func log(_ snapshot: [String: Any], at t: Date) {
        var clean: [String: Any] = [:]
        for (k, v) in snapshot where v is Double || v is Int || v is String || v is Bool { clean[k] = v }
        clean["received"] = t.timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]) else { return }
        let day = RecordingFormat.stamp(t, "yyyyMMdd")
        logQueue.async {
            if day != self.logDay || self.logHandle == nil {
                try? self.logHandle?.close()
                let fm = FileManager.default
                try? fm.createDirectory(at: Self.logRoot, withIntermediateDirectories: true)
                let url = Self.logRoot.appendingPathComponent("probe-live_\(day).jsonl")
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                self.logHandle = try? FileHandle(forWritingTo: url)
                _ = try? self.logHandle?.seekToEnd()
                self.logDay = day
                DispatchQueue.main.async { self.logFile = url }
            }
            var line = data
            line.append(0x0A)
            try? self.logHandle?.write(contentsOf: line)
            if let size = try? self.logHandle?.offset() {
                DispatchQueue.main.async { self.logBytes = Int64(size) }
            }
        }
    }

    // MARK: commands to the watch

    func send(_ command: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            status = "The watch link is not ready."
            return
        }
        let session = WCSession.default
        guard session.isReachable else {
            status = "Watch not reachable. Open Sage on the watch (or tap Open Sage on the watch)."
            return
        }
        status = "Sending \(command)…"
        session.sendMessage([ProbeLink.commandKey: command], replyHandler: { reply in
            let running = reply[ProbeLink.runningKey] as? Bool
            let since = (reply[ProbeLink.sinceKey] as? Double).map { Date(timeIntervalSince1970: $0) }
            DispatchQueue.main.async {
                self.watchRunning = running
                self.watchSince = since
                self.status = running == true ? "Probe is running on the watch." : "Probe is off on the watch."
            }
        }, errorHandler: { error in
            DispatchQueue.main.async { self.status = "Watch: \(error.localizedDescription)" }
        })
    }

    /// opens the app on the watch, which starts the probe (its workout session keeps it running); asks for its
    /// state a few seconds later
    func startOnWatch() {
        status = "Opening Sage on the watch…"
        HKHealthStore().startWatchApp(with: WatchLaunch.configuration()) { ok, error in
            DispatchQueue.main.async {
                if !ok {
                    self.status = "Could not open Sage on the watch: \(error?.localizedDescription ?? "unknown error")"
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.send(ProbeLink.status) }
            }
        }
    }

    func clearLive() {
        latest = [:]
        history = [:]
        wave = []
        snapshots = 0
        lastSnapshot = nil
    }
}

/// One stream of a probe segment on the iPhone: its chunk files merged, for the Lab tab's tables and charts.
struct ProbeStreamData {
    let columns: [String]
    /// rows, oldest first (at most `limit`)
    let rows: [[String]]
    let totalLines: Int
    let bytes: Int64

    /// reads the newest `maxBytes` of the stream's chunks (high-rate streams are large) and keeps the newest `limit` rows
    static func load(segment: URL, stream: String, limit: Int = 20_000, maxBytes: Int64 = 12_000_000) -> ProbeStreamData {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: segment.path)) ?? [])
            .filter { RecordingFormat.stream(ofFile: $0) == stream }
            .sorted()
        var sizes: [(String, Int64)] = []
        var total: Int64 = 0
        for n in names {
            let size = ((try? fm.attributesOfItem(atPath: segment.appendingPathComponent(n).path))?[.size] as? NSNumber)?.int64Value ?? 0
            sizes.append((n, size))
            total += size
        }
        var picked: [String] = []
        var budget = maxBytes
        for (n, size) in sizes.reversed() {
            if !picked.isEmpty && budget - size < 0 { break }
            picked.insert(n, at: 0)
            budget -= size
        }
        var columns: [String] = ProbeFormat.header(of: stream).components(separatedBy: ",")
        var rows: [[String]] = []
        var lines = 0
        for n in picked {
            guard let text = try? String(contentsOf: segment.appendingPathComponent(n), encoding: .utf8) else { continue }
            var first = true
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if first {
                    first = false
                    if RecordingFormat.lineTime(line) == nil {
                        columns = line.components(separatedBy: ",")
                        continue
                    }
                }
                lines += 1
                rows.append(line.components(separatedBy: ","))
            }
            if rows.count > limit * 2 { rows.removeFirst(rows.count - limit) }
        }
        if rows.count > limit { rows.removeFirst(rows.count - limit) }
        return ProbeStreamData(columns: columns, rows: rows, totalLines: lines, bytes: total)
    }

    /// the numeric columns (besides the time), for the chart's picker
    var numericColumns: [Int] {
        guard let sample = rows.last else { return [] }
        var out: [Int] = []
        for i in 1..<max(1, columns.count) where i < sample.count {
            if Double(sample[i]) != nil { out.append(i) }
        }
        return out
    }

    /// (time, value) of one column, thinned to at most `points`
    func series(column: Int, points: Int = 1500) -> [(Date, Double)] {
        let step = max(1, rows.count / points)
        var out: [(Date, Double)] = []
        out.reserveCapacity(min(rows.count, points + 1))
        var i = 0
        while i < rows.count {
            let r = rows[i]
            if r.count > column, let t = Double(r[0]), let v = Double(r[column]) {
                out.append((Date(timeIntervalSince1970: t), v))
            }
            i += step
        }
        return out
    }
}
