import Foundation

/// A CSV file that rotates on wall-clock boundaries (every `period` seconds) and hands each finished chunk to `Outbox`.
///
/// Not thread-safe: every call must come from the one queue that owns the writer.
final class RotatingCSV {
    let directory: URL
    let prefix: String
    let header: String
    let period: TimeInterval
    let segment: String

    private var handle: FileHandle?
    private var url: URL?
    private var chunkEnd: Double = 0
    private var buffer = ""
    private var buffered = 0
    private(set) var linesWritten = 0

    init(directory: URL, prefix: String, header: String, period: TimeInterval, segment: String) {
        self.directory = directory
        self.prefix = prefix
        self.header = header
        self.period = period
        self.segment = segment
    }

    /// Appends one line stamped with unix time `t`; opens or rotates the chunk as needed.
    func append(_ line: String, at t: Double) {
        if handle == nil || t >= chunkEnd { rotate(at: t) }
        buffer += line
        buffer += "\n"
        buffered += 1
        linesWritten += 1
        if buffered >= 250 { flush() }
    }

    func flush() {
        guard let h = handle, !buffer.isEmpty else { return }
        try? h.write(contentsOf: Data(buffer.utf8))
        buffer = ""
        buffered = 0
    }

    /// Writes what is buffered, closes the chunk and ships it.
    func close() {
        flush()
        try? handle?.close()
        handle = nil
        if let u = url { Outbox.shared.ship(u, segment: segment, compress: true) }
        url = nil
    }

    private func rotate(at t: Double) {
        close()
        chunkEnd = ((t / period).rounded(.down) + 1) * period
        // the name carries the moment the chunk was opened, so a chunk reopened after a restart never overwrites one already sent
        let name = "\(prefix)_\(RecordingFormat.stamp(Date(timeIntervalSince1970: t), "yyyyMMdd-HHmmss")).csv"
        let u = directory.appendingPathComponent(name)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: u.path) {
            fm.createFile(atPath: u.path, contents: Data((header + "\n").utf8))
        }
        handle = try? FileHandle(forWritingTo: u)
        _ = try? handle?.seekToEnd()
        url = u
    }
}
