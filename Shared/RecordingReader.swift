import Foundation

/// Reads the recorder's numeric CSV files quickly: straight from the bytes, no String per line.
///
/// Every data line of a recording starts with a unix time; most columns are numbers. A night of 50 Hz raw motion is
/// about a million lines, which this parses in well under a second on an iPhone.
enum CSVNumbers {
    /// The requested columns (0-based) of every line whose first column is a number inside [from, to).
    /// Header and damaged lines are skipped; a requested column that is missing or not a number reads as NaN.
    /// The result is column-major: `result[i]` holds the values of `columns[i]`.
    static func read(_ data: Data, columns: [Int], from lo: Double = -.infinity, to hi: Double = .infinity) -> [[Double]] {
        guard let maxColumn = columns.max(), maxColumn >= 0 else { return [] }
        var out = Array(repeating: [Double](), count: columns.count)
        guard !data.isEmpty else { return out }
        var bytes = [UInt8](data)
        bytes.append(0)                                   // strtod never reads past the end
        let estimate = max(16, data.count / 32)
        for i in out.indices { out[i].reserveCapacity(estimate) }

        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let count = buffer.count - 1
            var values = [Double](repeating: .nan, count: maxColumn + 1)
            var i = 0
            while i < count {
                for c in 0...maxColumn { values[c] = .nan }
                var column = 0
                while i < count && base[i] != 10 {               // one line
                    if column <= maxColumn && startsNumber(base[i]) {
                        var end: UnsafeMutablePointer<CChar>? = nil
                        let start = UnsafeMutableRawPointer(base + i).assumingMemoryBound(to: CChar.self)
                        let v = strtod(start, &end)
                        if let end, end > start {
                            values[column] = v
                            i += end - start
                        }
                    }
                    while i < count && base[i] != 44 && base[i] != 10 { i += 1 }   // rest of the field
                    if i < count && base[i] == 44 { i += 1; column += 1 }
                }
                i += 1
                let t = values[0]
                if t.isNaN || t < lo || t >= hi { continue }
                for (k, c) in columns.enumerated() { out[k].append(values[c]) }
            }
        }
        return out
    }

    /// digits, sign or decimal point: anything else (empty field, text) is not handed to strtod, which would
    /// otherwise skip whitespace and read the next line's number
    @inline(__always) private static func startsNumber(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || b == 45 || b == 43 || b == 46
    }

    /// Lines of a small text CSV (status, events, activity) split into fields, header dropped, inside [from, to).
    static func rows(_ data: Data, from lo: Double = -.infinity, to hi: Double = .infinity) -> [[Substring]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [[Substring]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = fields.first, let t = Double(first), t >= lo, t < hi else { continue }
            out.append(fields)
        }
        return out
    }
}

/// The chunk files the iPhone keeps in `Documents/Recordings/<segment>/`, indexed by stream and opening time, and
/// read back merged and in time order. Shared so the tests can point it at a folder of their own.
struct RecordingStore {
    struct Chunk: Hashable {
        let url: URL
        let stream: String
        let segment: String
        let opened: Double          // unix time the chunk was opened (from its name)
    }

    let root: URL
    /// no chunk spans more than this (old builds wrote 30- and 60-minute chunks; new ones 10 minutes)
    static let longestChunk: Double = 2 * 3600

    init(root: URL) { self.root = root }

    /// every chunk file, oldest first
    func chunks(stream: String? = nil) -> [Chunk] {
        let fm = FileManager.default
        var out: [Chunk] = []
        for seg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: seg, includingPropertiesForKeys: nil)) ?? [] {
                let name = f.lastPathComponent
                guard let s = RecordingFormat.stream(ofFile: name), stream == nil || s == stream,
                      let opened = RecordingFormat.openedAt(name) else { continue }
                out.append(Chunk(url: f, stream: s, segment: seg.lastPathComponent, opened: opened))
            }
        }
        return out.sorted { $0.opened != $1.opened ? $0.opened < $1.opened : $0.url.path < $1.url.path }
    }

    /// chunks of `stream` that may hold lines inside [lo, hi)
    func chunks(stream: String, from lo: Double, to hi: Double) -> [Chunk] {
        chunks(stream: stream).filter { $0.opened < hi && $0.opened + Self.longestChunk >= lo }
    }

    /// The numeric `columns` of `stream` inside [lo, hi), merged over all chunks and sorted by time (column 0 must be
    /// the time). Lines repeated across chunks (a chunk re-sent after a restart) are dropped.
    func numbers(_ stream: String, columns: [Int], from lo: Double, to hi: Double) -> [[Double]] {
        var cols = Array(repeating: [Double](), count: columns.count)
        for chunk in chunks(stream: stream, from: lo, to: hi) {
            guard let data = try? Data(contentsOf: chunk.url, options: .mappedIfSafe) else { continue }
            let part = CSVNumbers.read(data, columns: columns, from: lo, to: hi)
            for i in cols.indices { cols[i].append(contentsOf: part[i]) }
        }
        return Self.sortedUnique(cols)
    }

    /// Hands the numeric `columns` of `stream` inside [lo, hi) to `body` one chunk at a time, oldest first (for
    /// streams too big to merge in memory, like a night of raw motion).
    func forEachChunk(_ stream: String, columns: [Int], from lo: Double, to hi: Double, _ body: ([[Double]]) -> Void) {
        for chunk in chunks(stream: stream, from: lo, to: hi) {
            guard let data = try? Data(contentsOf: chunk.url, options: .mappedIfSafe) else { continue }
            let part = CSVNumbers.read(data, columns: columns, from: lo, to: hi)
            if let first = part.first, !first.isEmpty { body(part) }
        }
    }

    /// text rows of a small stream (status, events, activity) inside [lo, hi), in time order
    func rows(_ stream: String, from lo: Double, to hi: Double) -> [[String]] {
        var out: [(Double, [String])] = []
        for chunk in chunks(stream: stream, from: lo, to: hi) {
            guard let data = try? Data(contentsOf: chunk.url) else { continue }
            for r in CSVNumbers.rows(data, from: lo, to: hi) {
                out.append((Double(r[0]) ?? 0, r.map(String.init)))
            }
        }
        out.sort { $0.0 < $1.0 }
        var seen = Set<String>()
        return out.compactMap { seen.insert($0.1.joined(separator: ",")).inserted ? $0.1 : nil }
    }

    /// earliest and latest time with any data (first line of the oldest chunk, last line of the newest)
    func extent() -> ClosedRange<Double>? {
        let all = chunks()
        guard let first = all.first, let last = all.max(by: { $0.opened < $1.opened }) else { return nil }
        var hi = last.opened
        if let data = try? Data(contentsOf: last.url), let t = CSVNumbers.read(data, columns: [0]).first?.last { hi = max(hi, t) }
        return first.opened...max(first.opened, hi)
    }

    /// sorts column-major rows by the first column and drops exact time repeats
    static func sortedUnique(_ cols: [[Double]]) -> [[Double]] {
        guard let t = cols.first, t.count > 1 else { return cols }
        var sorted = true
        for i in 1..<t.count where t[i] < t[i - 1] { sorted = false; break }
        var order = Array(t.indices)
        if !sorted { order.sort { t[$0] != t[$1] ? t[$0] < t[$1] : $0 < $1 } }
        var keep: [Int] = []
        keep.reserveCapacity(order.count)
        for i in order where keep.isEmpty || t[i] != t[keep[keep.count - 1]] { keep.append(i) }
        if sorted && keep.count == t.count { return cols }
        return cols.map { c in keep.map { c[$0] } }
    }
}
