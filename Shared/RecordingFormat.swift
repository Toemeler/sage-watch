import Foundation

/// File layout shared by the watch and the iPhone.
///
/// The watch writes CSV chunks into a segment (one segment per probe run), compresses each finished chunk with zlib
/// (`.zz`) and sends it to the iPhone, which unpacks it into `Documents/Recordings/<segment>/`. Every data line starts
/// with a unix time in seconds, so chunks can be merged and cut to any time range.
enum RecordingFormat {
    static let metaName = "segment.json"
    static let compressedSuffix = ".zz"

    static func segmentID(for date: Date) -> String { stamp(date, "yyyyMMdd-HHmmss") }

    static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    static func unix(_ t: Double) -> String { String(format: "%.3f", t) }
    static func unix(_ d: Date) -> String { unix(d.timeIntervalSince1970) }

    /// a Core Motion log timestamp (CMLogItem.timestamp) in unix seconds. Documented as seconds since boot, and so
    /// it is for device motion; but the altimeter on watchOS 27 delivers seconds since 2001 (the reference date).
    /// A value past ~9.5 years of uptime can only be that.
    static func unixTime(logTimestamp ts: Double, bootOffset: Double) -> Double {
        ts > 3e8 ? ts + 978_307_200 : ts + bootOffset
    }

    /// the first column of a CSV line as a unix time; nil for a header or a malformed line
    static func lineTime<S: StringProtocol>(_ line: S) -> Double? {
        if let comma = line.firstIndex(of: ",") { return Double(line[line.startIndex..<comma]) }
        return Double(line)
    }

    /// which data stream a chunk file belongs to, from its name ("probe-motion_20261125-170012.csv" -> "probe-motion")
    static func stream(ofFile name: String) -> String? {
        guard name.hasSuffix(".csv"), let underscore = name.firstIndex(of: "_") else { return nil }
        return String(name[name.startIndex..<underscore])
    }
}
