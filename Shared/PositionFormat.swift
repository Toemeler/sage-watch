import Foundation

/// Streams for position tracking (watch and iPhone). Same rules as RecordingFormat: one line per sample, unix time
/// first, chunks named "<stream>_<yyyyMMdd-HHmmss>.csv" (stream names contain no underscore).
enum PositionFormat {
    /// every GPS / Wi-Fi fix: latitude, longitude (deg), altitude above sea level (m), horizontal and vertical
    /// accuracy (m, -1 = invalid), speed (m/s), course (deg from true north), floor (building level, empty if unknown)
    static let locationHeader = "unix_time,lat,lon,alt_m,h_acc_m,v_acc_m,speed_mps,course_deg,floor"
    /// orientation from the motion coprocessor (10 Hz): heading (deg from magnetic north, -1 if unavailable),
    /// attitude quaternion w,x,y,z, user acceleration x,y,z (g, gravity removed), rotation rate x,y,z (rad/s)
    static let headingHeader = "unix_time,heading_deg,qw,qx,qy,qz,ax,ay,az,rx,ry,rz"
    /// Apple's step counter, cumulative since the run started: steps, distance (m), floors up, floors down,
    /// cadence (steps/s), pace (s/m)
    static let stepsHeader = "unix_time,steps,distance_m,floors_up,floors_down,cadence,pace"
    /// absolute altitude from GPS + barometer: metres above sea level, accuracy and precision (m)
    static let altitudeHeader = "unix_time,altitude_m,accuracy_m,precision_m"

    static let location = "location", heading = "heading", steps = "steps", altitude = "altitude"
    /// the iPhone records the same streams under these names (plus its own barometer)
    static let phoneLocation = "phonelocation", phoneHeading = "phoneheading", phoneSteps = "phonesteps",
               phoneAltitude = "phonealtitude", phonePressure = "phonepressure", phoneStatus = "phonestatus"
    /// the iPhone's battery once a minute while tracking, so an export shows how fast tracking drains it
    static let statusHeader = "unix_time,battery,charging,gps_mode"

    static func location(t: Double, lat: Double, lon: Double, alt: Double, hAcc: Double, vAcc: Double,
                         speed: Double, course: Double, floor: Int?) -> String {
        "\(RecordingFormat.unix(t)),\(String(format: "%.7f", lat)),\(String(format: "%.7f", lon)),\(String(format: "%.2f", alt)),"
            + "\(String(format: "%.1f", hAcc)),\(String(format: "%.1f", vAcc)),\(String(format: "%.2f", speed)),"
            + "\(String(format: "%.1f", course)),\(floor.map(String.init) ?? "")"
    }

    static func heading(t: Double, heading: Double, q: (Double, Double, Double, Double),
                        a: (Double, Double, Double), r: (Double, Double, Double)) -> String {
        let f = RecordingFormat.f4
        return "\(RecordingFormat.unix(t)),\(String(format: "%.1f", heading)),\(f(q.0)),\(f(q.1)),\(f(q.2)),\(f(q.3)),"
            + "\(f(a.0)),\(f(a.1)),\(f(a.2)),\(f(r.0)),\(f(r.1)),\(f(r.2))"
    }

    static func steps(t: Double, steps: Int, distance: Double?, up: Int?, down: Int?, cadence: Double?, pace: Double?) -> String {
        let o = { (v: Double?) in v.map { String(format: "%.3f", $0) } ?? "" }
        return "\(RecordingFormat.unix(t)),\(steps),\(o(distance)),\(up.map(String.init) ?? ""),\(down.map(String.init) ?? ""),\(o(cadence)),\(o(pace))"
    }

    static func altitude(t: Double, altitude: Double, accuracy: Double, precision: Double) -> String {
        "\(RecordingFormat.unix(t)),\(String(format: "%.2f", altitude)),\(String(format: "%.2f", accuracy)),\(String(format: "%.2f", precision))"
    }
}

/// Decisions for position tracking, kept testable.
enum PositionRules {
    enum GPSMode: String, Equatable { case best, saver, minimal }

    /// Best accuracy while the battery allows; below 20 % (not charging) GPS drops to ~10 m accuracy, which costs far
    /// less; below 10 % to ~100 m and the iPhone's compass to 2 per second, a last reserve so the phone itself stays
    /// usable (27 Nov: the iPhone ran out at 12:10 while tracking). Back up with a gap each time (no flapping):
    /// minimal → saver above 15 %, saver → best above 30 %; on the charger always best.
    static func gpsMode(battery: Double?, charging: Bool, current: GPSMode) -> GPSMode {
        guard let b = battery, b >= 0, !charging else { return charging ? .best : current }
        if b < 0.10 { return .minimal }
        if b < 0.20 { return current == .minimal && b < 0.15 ? .minimal : .saver }
        if b > 0.30 { return .best }
        return current == .minimal ? .saver : current
    }
}

/// F28: one switch for position on both devices. Each side sends its own switch changes, made by you, with the
/// time; the other side follows when that change is newer than its own last one (so the two never fight, and a
/// message that arrives late never undoes a newer choice).
enum PositionSync {
    static let key = "trackPosition"
    static let changedAtKey = "positionChangedAt"

    static func message(on: Bool, at: Date) -> [String: Any] { [key: ["on": on, "at": at.timeIntervalSince1970]] }

    /// the change in a received message, if any
    static func change(in message: [String: Any]) -> (on: Bool, at: Double)? {
        guard let d = message[key] as? [String: Any], let on = d["on"] as? Bool, let at = d["at"] as? Double else { return nil }
        return (on, at)
    }

    /// follow a change from the other device only if it is newer than this device's own last change
    static func shouldFollow(remoteAt: Double, localAt: Double?) -> Bool {
        remoteAt > (localAt ?? 0)
    }

    static var localChangedAt: Double? {
        get { UserDefaults.standard.object(forKey: changedAtKey) as? Double }
        set { UserDefaults.standard.set(newValue, forKey: changedAtKey) }
    }
}
