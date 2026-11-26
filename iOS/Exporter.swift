import Foundation

/// Cuts the watch recordings to a time range, merges the chunks per stream and zips the result.
///
/// Output (one zip): hr.csv, motion1s.csv, raw.csv or raw_gyro.csv, pressure.csv, status.csv, activity.csv,
/// events.csv, health_sleep.csv (Apple Health's sleep), nights.json (Sage's analyses), segments.json, README.txt.
/// Chunks are streamed one at a time, so even an export of all data never sits in memory at once.
enum Exporter {
    struct Options {
        var includeRaw = true
        var health: [SleepHealth.Sample] = []
        var nights: Data? = nil
    }

    struct Result {
        let zip: URL
        let lines: [String: Int]
    }

    enum ExportError: LocalizedError {
        case nothing
        var errorDescription: String? { "No watch data in this time range yet." }
    }

    static var exportsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports", isDirectory: true)
    }

    /// the whole recorded span (for "All data")
    static func allData() -> DateInterval? {
        guard let e = RecordingStore(root: Receiver.root).extent() else { return nil }
        return DateInterval(start: Date(timeIntervalSince1970: e.lowerBound), end: max(Date(), Date(timeIntervalSince1970: e.upperBound)))
    }

    static func export(from: Date, to: Date, options: Options = Options(), progress: ((Double) -> Void)? = nil) throws -> Result {
        let fm = FileManager.default
        let lo = from.timeIntervalSince1970, hi = to.timeIntervalSince1970
        let name = "Sage_\(RecordingFormat.stamp(from, "yyyyMMdd-HHmm"))_\(RecordingFormat.stamp(to, "yyyyMMdd-HHmm"))"
        let work = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let store = RecordingStore(root: Receiver.root)
        let chunks = store.chunks().filter { c in
            (options.includeRaw || c.stream != RecordingFormat.rawPrefix) && c.opened < hi && c.opened + RecordingStore.longestChunk >= lo
        }
        var metas: [[String: Any]] = []
        for seg in (try? fm.contentsOfDirectory(at: Receiver.root, includingPropertiesForKeys: nil)) ?? [] {
            let meta = Receiver.meta(in: seg)
            guard let start = meta["start"] as? Double else { continue }
            let end = meta["end"] as? Double ?? Date().timeIntervalSince1970
            if end >= lo && start <= hi { metas.append(meta) }
        }

        var outputs: [String: FileHandle] = [:]
        var counts: [String: Int] = [:]
        defer { for h in outputs.values { try? h.close() } }

        for (i, chunk) in chunks.enumerated() {
            progress?(Double(i) / Double(max(1, chunks.count)))
            try autoreleasepool {
                guard let text = try? String(contentsOf: chunk.url, encoding: .utf8) else { return }
                let header = text.prefix { $0 != "\n" }
                let out = header == RecordingFormat.rawGyroHeader ? "raw_gyro" : chunk.stream
                let keep = RecordingFormat.lines(in: text, from: lo, to: hi)
                if keep.isEmpty { return }
                if outputs[out] == nil {
                    let u = work.appendingPathComponent("\(out).csv")
                    fm.createFile(atPath: u.path, contents: Data((String(header) + "\n").utf8))
                    outputs[out] = try FileHandle(forWritingTo: u)
                    _ = try outputs[out]?.seekToEnd()
                }
                var block = keep.joined(separator: "\n")
                block += "\n"
                try outputs[out]?.write(contentsOf: Data(block.utf8))
                counts[out, default: 0] += keep.count
            }
        }
        if counts.isEmpty { throw ExportError.nothing }

        let health = options.health.filter { $0.end >= lo && $0.start <= hi }
        if !health.isEmpty {
            var csv = "start,end,value\n"
            for s in health { csv += "\(RecordingFormat.unix(s.start)),\(RecordingFormat.unix(s.end)),\(s.value)\n" }
            try csv.write(to: work.appendingPathComponent("health_sleep.csv"), atomically: true, encoding: .utf8)
            counts["health_sleep"] = health.count
        }
        if let nights = options.nights { try nights.write(to: work.appendingPathComponent("nights.json")) }
        if let data = try? JSONSerialization.data(withJSONObject: metas, options: [.prettyPrinted, .sortedKeys]) {
            try data.write(to: work.appendingPathComponent("segments.json"))
        }
        try readme(from: from, to: to, counts: counts, raw: options.includeRaw)
            .write(to: work.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        for h in outputs.values { try? h.close() }
        outputs.removeAll()

        try fm.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        let zip = exportsRoot.appendingPathComponent("\(name).zip")
        try zipDirectory(work, to: zip)
        progress?(1)
        return Result(zip: zip, lines: counts)
    }

    /// Zips a folder with the system's own archiver (the "forUploading" read of a directory yields a zip).
    static func zipDirectory(_ dir: URL, to dest: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordinatorError) { zipped in
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipped, to: dest)
            } catch {
                copyError = error
            }
        }
        if let e = coordinatorError ?? copyError { throw e }
    }

    private static func readme(from: Date, to: Date, counts: [String: Int], raw: Bool) -> String {
        var s = """
        Sage watch recording export
        Range: \(from.formatted(date: .complete, time: .standard)) – \(to.formatted(date: .complete, time: .standard))
        Time zone: \(TimeZone.current.identifier)
        All times are unix seconds (UTC).\(raw ? "" : "\nRaw motion left out of this export.")

        hr.csv          heart rate from the workout session, about every 5 s
                        unix_start, unix_end, bpm
        motion1s.csv    one line per second of wrist motion
                        unix_second, samples, mean_g, sd_g (movement), mean_x/y/z (gravity = wrist position),
                        activity (summed |change| of acceleration, catches small twitches)
        raw.csv         raw accelerometer in g: unix_time, x, y, z
        raw_gyro.csv    raw accelerometer in g plus rotation rate in rad/s: unix_time, x, y, z, rx, ry, rz
        pressure.csv    barometer: unix_time, pressure_kpa, relative_altitude_m
        status.csv      once a minute: battery (0–1), battery_state (charging = off the wrist), last bpm, totals
        activity.csv    Apple's activity recognition, one line per change: unix_time, activity, confidence (0–2)
        events.csv      the smart alarm: unix_time, event, detail (window_open, asleep, ring, stop, nap_armed, ...)
        health_sleep.csv  Apple Health's sleep: start, end, value (asleep, core, deep, rem, awake, inBed)
        nights.json     Sage's analysis of every sleep in the last two weeks (stages, cycles, heart, breathing)
        segments.json   settings of each recording run (sample rate, gyroscope, watch, watchOS, battery)

        Lines:
        """
        for (k, v) in counts.sorted(by: { $0.key < $1.key }) { s += "\n  \(k).csv: \(v)" }
        return s + "\n"
    }
}
