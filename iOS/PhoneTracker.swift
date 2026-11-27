import CoreLocation
import CoreMotion
import SwiftUI

/// Position tracking on the iPhone, the companion to the watch's: the iPhone in a pocket is the steadier step and
/// heading sensor and usually has the better GPS (dual-frequency on newer models), so both are recorded and
/// combined afterwards (tools/track3d.py).
///
/// Streams (Recordings/phone-<start>/, exported with the watch's): phonelocation (every fix, best accuracy),
/// phoneheading (10 Hz: compass heading, attitude, user acceleration, rotation), phonesteps (step counter with
/// floors), phonealtitude (absolute altitude), phonepressure (barometer, relative altitude).
///
/// Runs in the background through the location background mode (the blue location indicator shows while it runs).
/// Threading: start/stop and the published values on the main thread; the files only on `queue`.
final class PhoneTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = PhoneTracker()

    @Published private(set) var running = false
    @Published private(set) var lastFix: CLLocation?
    @Published private(set) var steps = 0
    @Published private(set) var floorsUp = 0
    @Published private(set) var floorsDown = 0
    @Published private(set) var problem: String?

    private let manager = CLLocationManager()
    private let motion = CMMotionManager()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()
    private var files: [String: PhoneCSV] = [:]          // owned by queue
    private var segmentDir: URL?
    private var started: Date?
    private var gpsMode = PositionRules.GPSMode.best
    private var batteryTimer: Timer?
    @Published private(set) var saver = false

    override init() {
        super.init()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        if UserDefaults.standard.bool(forKey: "phoneTracking") { start() }      // resume after a relaunch
    }

    func start() {
        guard !running else { return }
        let now = Date()
        let dir = Receiver.root.appendingPathComponent("phone-" + RecordingFormat.segmentID(for: now), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        segmentDir = dir
        started = now
        writeMeta(end: nil)
        UserDefaults.standard.set(true, forKey: "phoneTracking")
        running = true
        problem = nil
        queue.addOperation {
            self.files = [
                PositionFormat.phoneLocation: PhoneCSV(dir, PositionFormat.phoneLocation, PositionFormat.locationHeader),
                PositionFormat.phoneHeading: PhoneCSV(dir, PositionFormat.phoneHeading, PositionFormat.headingHeader),
                PositionFormat.phoneSteps: PhoneCSV(dir, PositionFormat.phoneSteps, PositionFormat.stepsHeader),
                PositionFormat.phoneAltitude: PhoneCSV(dir, PositionFormat.phoneAltitude, PositionFormat.altitudeHeader),
                PositionFormat.phonePressure: PhoneCSV(dir, PositionFormat.phonePressure, RecordingFormat.pressureHeader)
            ]
        }

        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        // if iOS closes Sage in the background (memory), a significant location change relaunches it, and init
        // resumes tracking; plain location updates alone would end the day's recording silently
        if CLLocationManager.significantLocationChangeMonitoringAvailable() { manager.startMonitoringSignificantLocationChanges() }
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.checkBattery() }
        checkBattery()

        let bootOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        if motion.isDeviceMotionAvailable {
            let frames = CMMotionManager.availableAttitudeReferenceFrames()
            let frame: CMAttitudeReferenceFrame = frames.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryCorrectedZVertical
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] d, _ in
                guard let self, let d else { return }
                let t = d.timestamp + bootOffset
                let q = d.attitude.quaternion, a = d.userAcceleration, r = d.rotationRate
                self.files[PositionFormat.phoneHeading]?.append(
                    PositionFormat.heading(t: t, heading: d.heading, q: (q.w, q.x, q.y, q.z), a: (a.x, a.y, a.z), r: (r.x, r.y, r.z)), t)
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: now) { [weak self] d, _ in
                guard let self, let d else { return }
                let t = d.endDate.timeIntervalSince1970
                let line = PositionFormat.steps(t: t, steps: d.numberOfSteps.intValue, distance: d.distance?.doubleValue,
                                                up: d.floorsAscended?.intValue, down: d.floorsDescended?.intValue,
                                                cadence: d.currentCadence?.doubleValue, pace: d.currentPace?.doubleValue)
                self.queue.addOperation { self.files[PositionFormat.phoneSteps]?.append(line, t) }
                DispatchQueue.main.async {
                    self.steps = d.numberOfSteps.intValue
                    self.floorsUp = d.floorsAscended?.intValue ?? 0
                    self.floorsDown = d.floorsDescended?.intValue ?? 0
                }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] d, _ in
                guard let self, let d else { return }
                let t = d.timestamp + bootOffset
                self.files[PositionFormat.phonePressure]?.append(
                    "\(RecordingFormat.unix(t)),\(String(format: "%.4f", d.pressure.doubleValue)),\(String(format: "%.2f", d.relativeAltitude.doubleValue))", t)
            }
        }
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: queue) { [weak self] d, _ in
                guard let self, let d else { return }
                let t = Date().timeIntervalSince1970
                self.files[PositionFormat.phoneAltitude]?.append(
                    PositionFormat.altitude(t: t, altitude: d.altitude, accuracy: d.accuracy, precision: d.precision), t)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        UserDefaults.standard.set(false, forKey: "phoneTracking")
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        batteryTimer?.invalidate(); batteryTimer = nil
        motion.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        altimeter.stopAbsoluteAltitudeUpdates()
        queue.addOperation {
            for f in self.files.values { f.close() }
            self.files = [:]
        }
        writeMeta(end: Date())
    }

    /// below 20 % battery GPS drops to ~10 m accuracy so the recording lasts the day (PositionRules, tested)
    private func checkBattery() {
        let d = UIDevice.current
        let level = d.batteryLevel >= 0 ? Double(d.batteryLevel) : nil
        let charging = d.batteryState == .charging || d.batteryState == .full
        let next = PositionRules.gpsMode(battery: level, charging: charging, current: gpsMode)
        guard next != gpsMode else { return }
        gpsMode = next
        manager.desiredAccuracy = next == .best ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyNearestTenMeters
        saver = next == .saver
    }

    private func writeMeta(end: Date?) {
        guard let dir = segmentDir, let started else { return }
        var meta: [String: Any] = ["segment": dir.lastPathComponent, "start": started.timeIntervalSince1970,
                                   "device": "iPhone", "track_position": true, "time_zone": TimeZone.current.identifier]
        if let end { meta["end"] = end.timeIntervalSince1970 }
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent(RecordingFormat.metaName), options: .atomic)
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let lines = locations.map { l in
            (l.timestamp.timeIntervalSince1970,
             PositionFormat.location(t: l.timestamp.timeIntervalSince1970, lat: l.coordinate.latitude, lon: l.coordinate.longitude,
                                     alt: l.altitude, hAcc: l.horizontalAccuracy, vAcc: l.verticalAccuracy, speed: l.speed,
                                     course: l.course, floor: l.floor?.level))
        }
        let last = locations.last
        queue.addOperation { for (t, line) in lines { self.files[PositionFormat.phoneLocation]?.append(line, t) } }
        if let last { DispatchQueue.main.async { self.lastFix = last } }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            if status == .denied || status == .restricted {
                self.problem = "Location is off for Sage: Settings › Privacy & Security › Location Services › Sage."
            } else if self.running {
                self.manager.startUpdatingLocation()
            }
        }
    }
}

/// A CSV that rotates every 10 minutes into "<stream>_<stamp>.csv", written straight into the recordings folder
/// (the iPhone's own streams need no shipping). Not thread-safe: one queue owns it.
final class PhoneCSV {
    private let dir: URL, stream: String, header: String
    private var handle: FileHandle?
    private var chunkEnd: Double = 0
    private var buffer = ""
    private var lastFlush: Double = 0

    init(_ dir: URL, _ stream: String, _ header: String) {
        self.dir = dir; self.stream = stream; self.header = header
    }

    func append(_ line: String, _ t: Double) {
        if handle == nil || t >= chunkEnd { rotate(t) }
        buffer += line + "\n"
        if buffer.utf8.count > 16_000 || t - lastFlush >= 20 { flush(); lastFlush = t }
    }

    func flush() {
        guard let h = handle, !buffer.isEmpty else { return }
        try? h.write(contentsOf: Data(buffer.utf8))
        buffer = ""
    }

    func close() {
        flush()
        try? handle?.close()
        handle = nil
    }

    private func rotate(_ t: Double) {
        close()
        let period = RecordingFormat.chunkSeconds
        chunkEnd = ((t / period).rounded(.down) + 1) * period
        let opened = chunkEnd - period
        let url = dir.appendingPathComponent("\(stream)_\(RecordingFormat.stamp(Date(timeIntervalSince1970: opened), "yyyyMMdd-HHmmss")).csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data((header + "\n").utf8))
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}

/// The iPhone's position tracking in the Data tab: on/off, the last fix and what has been counted.
struct PhoneTrackerCard: View {
    @ObservedObject private var tracker = PhoneTracker.shared
    /// builds today's export without raw motion (the share button appears in Export below)
    var exportToday: () -> Void = {}

    var body: some View {
        Section {
            Toggle("Track position on this iPhone", isOn: Binding(get: { tracker.running }, set: { $0 ? tracker.start() : tracker.stop() }))
            if tracker.running {
                if let f = tracker.lastFix {
                    LabeledContent("GPS", value: "±\(Int(f.horizontalAccuracy.rounded())) m · \(f.timestamp.formatted(date: .omitted, time: .shortened))")
                    LabeledContent("Height", value: "\(Int(f.altitude.rounded())) m ±\(Int(f.verticalAccuracy.rounded()))")
                } else {
                    LabeledContent("GPS", value: "waiting for a fix…")
                }
                LabeledContent("Steps", value: "\(tracker.steps)")
                LabeledContent("Floors", value: "↑\(tracker.floorsUp)  ↓\(tracker.floorsDown)")
                if tracker.saver { Text("Battery below 20 %: GPS saves power (~10 m)").font(.footnote).foregroundStyle(.orange) }
            }
            if let p = tracker.problem { Text(p).font(.footnote).foregroundStyle(.red) }
            Button("Export today's position data") { exportToday() }
        } header: {
            Text("Position")
        } footer: {
            Text("Records GPS, compass, steps and floors on the iPhone, together with the watch's (turn on Track position there too). Keep the iPhone in a pocket. Uses a lot of battery. \"Export today's position data\" builds today without raw motion (small, quick); share it from Export below.")
        }
    }
}
