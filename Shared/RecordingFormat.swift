import Foundation

/// File layout shared by the watch recorder and the iPhone side.
///
/// The watch writes CSV chunks into a segment (one segment per recording run), compresses each finished chunk
/// with zlib (`.zz`) and sends it to the iPhone, which unpacks it into `Documents/Recordings/<segment>/`.
/// Every data line starts with a unix time in seconds, so chunks can be merged and cut to any time range.
enum RecordingFormat {
    /// heart rate from the workout session (about every 5 s)
    static let heartPrefix = "hr"
    static let heartHeader = "unix_start,unix_end,bpm"
    /// one line per second: how much the wrist moved, and where gravity points (sleep position)
    static let summaryPrefix = "motion1s"
    static let summaryHeader = "unix_second,samples,mean_g,sd_g,mean_x,mean_y,mean_z,activity"
    /// raw accelerometer (g)
    static let rawPrefix = "raw"
    static let rawHeader = "unix_time,x,y,z"
    /// raw accelerometer (g) plus gyroscope rotation rate (rad/s)
    static let rawGyroHeader = "unix_time,x,y,z,rx,ry,rz"
    /// barometer: air pressure (kPa) and altitude change since the run started (m)
    static let pressurePrefix = "pressure"
    static let pressureHeader = "unix_time,pressure_kpa,relative_altitude_m"
    /// once a minute: battery, charging (on the charger = off the wrist) and running totals
    static let statusPrefix = "status"
    static let statusHeader = "unix_time,battery,battery_state,last_bpm,heart_samples,motion_samples"
    /// the smart alarm's log: when a wake window opened, when you fell asleep for a nap, when and why it rang and stopped
    static let eventsPrefix = "events"
    static let eventsHeader = "unix_time,event,detail"
    /// what Apple's motion coprocessor says you are doing, one line per change
    static let activityPrefix = "activity"
    static let activityHeader = "unix_time,activity,confidence"
    /// every stream rotates on 10-minute boundaries: an update or a crash loses at most the open 10 minutes
    static let chunkSeconds: Double = 600
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

    /// a Core Motion log timestamp (CMLogItem.timestamp) in unix seconds. Documented as seconds since boot, and so
    /// it is for device motion; but the altimeter on watchOS 27 delivers seconds since 2001 (the reference date):
    /// the watch's barometer was written ~26 years in the future (exports "ending" in 2052). A value past ~9.5
    /// years of uptime can only be that.
    static func unixTime(logTimestamp ts: Double, bootOffset: Double) -> Double {
        ts > 3e8 ? ts + 978_307_200 : ts + bootOffset
    }
    static func unix(_ d: Date) -> String { unix(d.timeIntervalSince1970) }
    static func f4(_ v: Double) -> String { String(format: "%.4f", v) }

    /// the first column of a CSV line as a unix time; nil for a header or a malformed line
    static func lineTime<S: StringProtocol>(_ line: S) -> Double? {
        if let comma = line.firstIndex(of: ",") { return Double(line[line.startIndex..<comma]) }
        return Double(line)
    }

    /// the data lines of `csv` whose time lies in [from, to] (the header is dropped)
    static func lines(in csv: String, from: Double, to: Double) -> [Substring] {
        csv.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            guard let t = lineTime(line) else { return false }
            return t >= from && t <= to
        }
    }

    /// "hr_20261125-170012.csv" -> the unix time the chunk was opened (the watch's local time, same zone as the iPhone)
    static func openedAt(_ file: String) -> Double? {
        guard let underscore = file.firstIndex(of: "_") else { return nil }
        let stamp = file[file.index(after: underscore)...].prefix(15)
        guard stamp.count == 15 else { return nil }
        return stampParser.date(from: String(stamp))?.timeIntervalSince1970
    }

    private static let stampParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// which data stream a chunk file belongs to, from its name ("hr_20261125-170012.csv" -> "hr")
    static func stream(ofFile name: String) -> String? {
        guard name.hasSuffix(".csv"), let underscore = name.firstIndex(of: "_") else { return nil }
        return String(name[name.startIndex..<underscore])
    }
}

/// What the smart alarm writes to the events stream.
enum AlarmEvent: String {
    case windowOpen = "window_open"         // a wake window began (detail: night / nap)
    case asleep = "asleep"                  // the moment you fell asleep (time = that moment; detail: nap / night)
    case ring = "ring"                      // the alarm started (detail: block and reason)
    case stop = "stop"                      // the alarm stopped (detail: button, shake, iphone, timeout, ended)
    case napArmed = "nap_armed"             // "Nap now"
    case napCancelled = "nap_cancelled"
    case testStart = "test_start"
    case testStop = "test_stop"
}

/// Folds accelerometer samples into one summary line per second.
///
/// `activity` is the summed absolute change of |a| between consecutive samples, a sensitive movement measure
/// that also catches small twitches; `mean_x/y/z` is the gravity direction, i.e. how the wrist lies.
struct MotionSummarizer {
    private var second = Int.min
    private var n = 0
    private var sum = 0.0, sum2 = 0.0
    private var sx = 0.0, sy = 0.0, sz = 0.0
    private var activity = 0.0
    private var previous: Double?
    /// the second most recently finished, as numbers (the live sleep detectors read it)
    private(set) var lastSecond: MotionSecond?

    /// Adds one sample. When the sample starts a new second, the finished line of the previous second is returned.
    mutating func add(t: Double, x: Double, y: Double, z: Double) -> String? {
        let s = Int(t.rounded(.down))
        var finished: String? = nil
        if s != second {
            finished = flush()
            second = s
        }
        let m = (x * x + y * y + z * z).squareRoot()
        n += 1
        sum += m
        sum2 += m * m
        sx += x
        sy += y
        sz += z
        if let p = previous { activity += abs(m - p) }
        previous = m
        return finished
    }

    /// The line for the current second (if it has samples), and a fresh start.
    mutating func flush() -> String? {
        guard n > 0, second != Int.min else { return nil }
        let count = Double(n)
        let mean = sum / count
        let variance = n > 1 ? max(0, (sum2 - count * mean * mean) / (count - 1)) : 0
        let f = RecordingFormat.f4
        let line = "\(second),\(n),\(f(mean)),\(f(variance.squareRoot())),\(f(sx / count)),\(f(sy / count)),\(f(sz / count)),\(f(activity))"
        lastSecond = MotionSecond(t: Double(second), sd: variance.squareRoot(), gx: sx / count, gy: sy / count, gz: sz / count)
        n = 0
        sum = 0; sum2 = 0
        sx = 0; sy = 0; sz = 0
        activity = 0
        return line
    }
}
