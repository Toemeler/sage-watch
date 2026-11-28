import Foundation

/// Data lab (test build): the watch's data probe records every sensor and Health type the watch offers, ships the
/// files to the iPhone like the recorder's (2-minute chunks, so they arrive quickly), and streams a snapshot of the
/// newest values once a second while the iPhone is reachable.
enum ProbeLink {
    /// iPhone → watch (sendMessage with reply): [commandKey: start / stop / ship / status]
    static let commandKey = "probe"
    static let start = "start", stop = "stop", ship = "ship", status = "status"
    /// watch → iPhone, once a second: [snapshotKey: [String: Double or String], waveKey: Float32 |a| at 50 Hz]
    static let snapshotKey = "probeSnapshot"
    static let waveKey = "probeWave"
    /// in the reply to a command: is the probe running, since when (unix seconds)
    static let runningKey = "probeRunning"
    static let sinceKey = "probeSince"

    static func packWave(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpackWave(_ data: Data) -> [Float] {
        let n = data.count / MemoryLayout<Float>.size
        guard n > 0 else { return [] }
        var f = [Float](repeating: 0, count: n)
        _ = f.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return f
    }
}

/// The probe's streams. Same rules as RecordingFormat: unix time first, chunks "<stream>_<yyyyMMdd-HHmmss>.csv",
/// stream names without an underscore. The segment is "probe-<yyyyMMdd-HHmmss>".
enum ProbeFormat {
    static let segmentPrefix = "probe-"
    /// short chunks: a test wants to see its data on the iPhone soon
    static let chunkSeconds: Double = 120

    /// 50 Hz device motion: user acceleration (g), gravity (g), rotation rate (rad/s), attitude quaternion,
    /// roll/pitch/yaw (rad), compass heading (deg, -1 if unknown), calibrated magnetic field (µT) and its accuracy (-1…2)
    static let motion = "probe-motion"
    static let motionHeader = "unix_time,ax,ay,az,gx,gy,gz,rx,ry,rz,qw,qx,qy,qz,roll,pitch,yaw,heading_deg,mx,my,mz,mag_accuracy"
    /// 800 Hz accelerometer (g) from the batched sensor manager (watches that have it, during a workout)
    static let accel = "probe-accel800"
    static let accelHeader = "unix_time,x,y,z"
    /// 200 Hz device motion from the batched sensor manager
    static let fastMotion = "probe-motion200"
    static let fastMotionHeader = "unix_time,ax,ay,az,gx,gy,gz,rx,ry,rz,qw,qx,qy,qz"
    /// barometer: pressure (kPa), altitude change since the probe started (m)
    static let pressure = "probe-baro"
    static let pressureHeader = "unix_time,pressure_kpa,relative_altitude_m"
    /// absolute altitude (GPS + barometer)
    static let altitude = "probe-altitude"
    static let altitudeHeader = "unix_time,altitude_m,accuracy_m,precision_m"
    /// Apple's step counter since the probe started (cumulative)
    static let steps = "probe-steps"
    static let stepsHeader = "unix_time,steps,distance_m,floors_up,floors_down,cadence_sps,pace_spm,avg_pace_spm"
    /// pedometer pause / resume
    static let stepEvents = "probe-stepevents"
    static let stepEventsHeader = "unix_time,event"
    /// every motion-activity update with all flags (1/0) and confidence (0 low, 1 medium, 2 high)
    static let activity = "probe-activity"
    static let activityHeader = "unix_time,stationary,walking,running,cycling,automotive,unknown,confidence"
    /// every location fix
    static let location = "probe-location"
    static let locationHeader = "unix_time,lat,lon,alt_m,ellipsoidal_alt_m,h_acc_m,v_acc_m,speed_mps,speed_acc,course_deg,course_acc,floor"
    /// compass from Core Location
    static let compass = "probe-compass"
    static let compassHeader = "unix_time,magnetic_deg,true_deg,accuracy_deg,x,y,z"
    /// every Health sample the watch holds (24 h back, then live): quantities, categories, heartbeat series, workouts
    static let health = "probe-health"
    static let healthHeader = "unix_start,unix_end,type,value,unit,source,device"
    /// beat-to-beat times from heartbeat series (the HRV readings)
    static let beats = "probe-beats"
    static let beatsHeader = "unix_time,series_start,offset_s,preceded_by_gap"
    /// every 5 s: the watch itself
    static let device = "probe-device"
    static let deviceHeader = "unix_time,battery,battery_state,thermal,low_power,water_lock,wrist,crown,app_state,reachable,uptime_s,free_mb,workout_session,files_waiting,lines_total"

    /// the big streams (an export without raw motion leaves them out)
    static let highRate: Set<String> = [motion, accel, fastMotion]

    static let all: [String] = [health, beats, motion, accel, fastMotion, pressure, altitude, steps, stepEvents,
                                activity, location, compass, device]

    static func header(of stream: String) -> String {
        switch stream {
        case motion: return motionHeader
        case accel: return accelHeader
        case fastMotion: return fastMotionHeader
        case pressure: return pressureHeader
        case altitude: return altitudeHeader
        case steps: return stepsHeader
        case stepEvents: return stepEventsHeader
        case activity: return activityHeader
        case location: return locationHeader
        case compass: return compassHeader
        case health: return healthHeader
        case beats: return beatsHeader
        case device: return deviceHeader
        default: return "unix_time,value"
        }
    }

    static func title(of stream: String) -> String {
        switch stream {
        case motion: return "Device motion 50 Hz"
        case accel: return "Accelerometer 800 Hz"
        case fastMotion: return "Device motion 200 Hz"
        case pressure: return "Barometer"
        case altitude: return "Absolute altitude"
        case steps: return "Pedometer"
        case stepEvents: return "Pedometer pause/resume"
        case activity: return "Motion activity"
        case location: return "Location"
        case compass: return "Compass"
        case health: return "Health samples"
        case beats: return "Heartbeat intervals"
        case device: return "Watch status"
        default: return stream
        }
    }

    /// a value that goes into one CSV field: no commas, no line breaks
    static func field(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
    }

    /// "HKQuantityTypeIdentifierHeartRate" -> "HeartRate"
    static func shortType(_ identifier: String) -> String {
        for p in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKDataTypeIdentifier", "HKWorkoutTypeIdentifier"]
        where identifier.hasPrefix(p) {
            return String(identifier.dropFirst(p.count))
        }
        return identifier
    }
}
