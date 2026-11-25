import Foundation

/// Cuts the watch recordings to a time range, merges the chunks per stream and zips the result.
///
/// Output (one zip): hr.csv, motion1s.csv, raw.csv or raw_gyro.csv, pressure.csv, status.csv, segments.json, README.txt.
enum Exporter {
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

    static func export(from: Date, to: Date) throws -> Result {
        let fm = FileManager.default
        let lo = from.timeIntervalSince1970, hi = to.timeIntervalSince1970
        let name = "Sage_\(RecordingFormat.stamp(from, "yyyyMMdd-HHmm"))_\(RecordingFormat.stamp(to, "yyyyMMdd-HHmm"))"
        let work = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // every chunk file of every segment, oldest first per stream
        var chunks: [(stream: String, url: URL)] = []
        var metas: [[String: Any]] = []
        for seg in (try? fm.contentsOfDirectory(at: Receiver.root, includingPropertiesForKeys: nil)) ?? [] {
            let meta = Receiver.meta(in: seg)
            if let start = meta["start"] as? Double {
                let end = meta["end"] as? Double ?? Date().timeIntervalSince1970
                if end < lo || start > hi { continue }
                metas.append(meta)
            }
            for f in (try? fm.contentsOfDirectory(at: seg, includingPropertiesForKeys: nil)) ?? [] {
                guard let stream = RecordingFormat.stream(ofFile: f.lastPathComponent) else { continue }
                if let opened = openedAt(f.lastPathComponent), opened > hi || opened + 7200 < lo { continue }
                chunks.append((stream, f))
            }
        }
        chunks.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }

        var outputs: [String: FileHandle] = [:]
        var counts: [String: Int] = [:]
        defer { for h in outputs.values { try? h.close() } }

        for chunk in chunks {
            guard let text = try? String(contentsOf: chunk.url, encoding: .utf8) else { continue }
            let header = text.prefix { $0 != "\n" }
            let out = header == RecordingFormat.rawGyroHeader ? "raw_gyro" : chunk.stream
            let keep = RecordingFormat.lines(in: text, from: lo, to: hi)
            if keep.isEmpty { continue }
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
        if counts.isEmpty { throw ExportError.nothing }

        if let data = try? JSONSerialization.data(withJSONObject: metas, options: [.prettyPrinted, .sortedKeys]) {
            try data.write(to: work.appendingPathComponent("segments.json"))
        }
        try readme(from: from, to: to, counts: counts).write(to: work.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        for h in outputs.values { try? h.close() }
        outputs.removeAll()

        try fm.createDirectory(at: exportsRoot, withIntermediateDirectories: true)
        let zip = exportsRoot.appendingPathComponent("\(name).zip")
        try zipDirectory(work, to: zip)
        try? fm.removeItem(at: work)
        return Result(zip: zip, lines: counts)
    }

    /// "hr_20261125-170012.csv" -> the unix time the chunk was opened (local time on the watch)
    private static func openedAt(_ file: String) -> Double? {
        guard let underscore = file.firstIndex(of: "_") else { return nil }
        let stamp = file[file.index(after: underscore)...].prefix(15)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.date(from: String(stamp))?.timeIntervalSince1970
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

    private static func readme(from: Date, to: Date, counts: [String: Int]) -> String {
        var s = """
        Sage watch recording export
        Range: \(from.formatted(date: .complete, time: .standard)) – \(to.formatted(date: .complete, time: .standard))
        Time zone: \(TimeZone.current.identifier)
        All times are unix seconds (UTC).

        hr.csv          heart rate from the workout session, about every 5 s
                        unix_start, unix_end, bpm
        motion1s.csv    one line per second of wrist motion
                        unix_second, samples, mean_g, sd_g (movement), mean_x/y/z (gravity = wrist position),
                        activity (summed |change| of acceleration, catches small twitches)
        raw.csv         raw accelerometer in g: unix_time, x, y, z
        raw_gyro.csv    raw accelerometer in g plus rotation rate in rad/s: unix_time, x, y, z, rx, ry, rz
        pressure.csv    barometer: unix_time, pressure_kpa, relative_altitude_m
        status.csv      once a minute: battery (0–1), battery_state (charging = off the wrist), last bpm, totals
        segments.json   settings of each recording run (sample rate, gyroscope, watch, watchOS, battery)

        Lines:
        """
        for (k, v) in counts.sorted(by: { $0.key < $1.key }) { s += "\n  \(k).csv: \(v)" }
        return s + "\n"
    }
}
