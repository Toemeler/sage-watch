import Foundation
import CoreLocation
import CoreMotion
import HealthKit
import WatchConnectivity
import WatchKit

/// Data lab (test build): records everything the watch can measure, as fast as it can, and sends it to the iPhone.
///
/// - files (ProbeFormat streams, 2-minute chunks through `Outbox`): device motion 50 Hz, the batched 800 Hz
///   accelerometer and 200 Hz device motion, barometer, absolute altitude, pedometer, motion activity, GPS, compass,
///   every Health sample the watch holds (24 h back, then live), heartbeat intervals, and the watch's own status;
/// - a snapshot of the newest values once a second over `sendMessage` while the iPhone is reachable.
///
/// A Mind & Body workout session keeps the app running in the background (and the batched sensors only deliver
/// during a workout); the workout is discarded when the probe stops, so nothing is saved to Health.
/// Switched on the watch or from the iPhone.
final class DataProbe: NSObject, ObservableObject, CLLocationManagerDelegate, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    static let shared = DataProbe()

    @Published private(set) var running = false
    /// the workout session that keeps the probe alive is running
    @Published private(set) var sessionRunning = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var totalLines = 0
    @Published private(set) var streamLines: [String: Int] = [:]
    @Published private(set) var sentSnapshots = 0
    /// what is not available on this watch, and errors (newest last)
    @Published private(set) var notes: [String] = []
    /// the 800 Hz accelerometer and 200 Hz device motion (large: ~100 MB an hour before compression)
    @Published var highRate: Bool { didSet { UserDefaults.standard.set(highRate, forKey: Keys.highRate) } }
    /// GPS and compass (battery)
    @Published var gps: Bool { didSet { UserDefaults.standard.set(gps, forKey: Keys.gps) } }

    /// the probe was on when Sage last ran: switch it back on at launch
    var wantsOn: Bool { UserDefaults.standard.bool(forKey: Keys.on) }

    private enum Keys {
        static let on = "probe.on", highRate = "probe.highRate", gps = "probe.gps"
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Probe", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "sage.probe", qos: .utility)
    private lazy var opQueue: OperationQueue = {
        let q = OperationQueue()
        q.underlyingQueue = queue
        q.maxConcurrentOperationCount = 1
        q.name = "sage.probe.ops"
        return q
    }()

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private var batched: CMBatchedSensorManager?
    private var batchTasks: [Task<Void, Never>] = []
    private var location: CLLocationManager?       // main thread
    private let store = HKHealthStore()
    private var session: HKWorkoutSession?           // main thread
    private var builder: HKLiveWorkoutBuilder?
    private var healthQueries: [HKQuery] = []        // main thread
    private var statusTimer: Timer?                  // main thread
    private var snapshotTimer: DispatchSourceTimer?

    // owned by queue
    private var segment: String?
    private var directory: URL?
    private var files: [String: RotatingCSV] = [:]
    private var counts: [String: Int] = [:]
    private var lineCount = 0
    private var latest: [String: Any] = [:]
    private var wave: [Float] = []
    private var bootOffset: TimeInterval = 0
    private var motionSamples = 0
    private var units: [HKQuantityType: HKUnit] = [:]
    private var seenSeries = Set<UUID>()

    private override init() {
        let d = UserDefaults.standard
        highRate = d.object(forKey: Keys.highRate) as? Bool ?? true
        gps = d.object(forKey: Keys.gps) as? Bool ?? true
        super.init()
    }

    // MARK: start / stop (main thread)

    /// `recovered`: a session watchOS handed back after relaunching the app in the middle of a run
    func start(recovered: HKWorkoutSession? = nil) {
        guard !running else { return }
        // a recovery in flight decides itself (a second workout session would fail)
        if recovered == nil && recovering { return }
        UserDefaults.standard.set(true, forKey: Keys.on)
        let now = Date()
        let id = ProbeFormat.segmentPrefix + RecordingFormat.segmentID(for: now)
        let dir = Self.root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Outbox.shared.shipLeftovers(in: Self.root, except: id)
        let offset = now.timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        queue.async {
            self.segment = id
            self.directory = dir
            self.files = [:]
            self.counts = [:]
            self.lineCount = 0
            self.latest = [:]
            self.wave = []
            self.motionSamples = 0
            self.seenSeries = []
            self.bootOffset = offset
        }
        notes = []
        running = true
        startedAt = now
        writeMeta(segment: id, start: now, end: nil)

        startMotion()
        startAltimeter()
        startPedometer(since: now)
        startActivity()
        if gps { startLocation() }
        // Health access first: the workout session needs it, then the batched sensors need the session
        startHealth(since: now, recovered: recovered)
        startTimers()
    }

    /// watchOS relaunched the app while its workout session was still running: take it back
    private var recovering = false

    func recover() {
        recovering = true
        store.recoverActiveWorkoutSession { [weak self] recovered, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.recovering = false
                if self.running {
                    if let s = recovered, self.session == nil { self.adopt(s, start: Date()) }
                    return
                }
                if let s = recovered {
                    self.start(recovered: s)
                } else if self.wantsOn {
                    self.start()
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        UserDefaults.standard.set(false, forKey: Keys.on)
        endSession()
        motion.stopDeviceMotionUpdates()
        stopBatched()
        altimeter.stopRelativeAltitudeUpdates()
        altimeter.stopAbsoluteAltitudeUpdates()
        pedometer.stopUpdates()
        pedometer.stopEventUpdates()
        activityManager.stopActivityUpdates()
        location?.stopUpdatingLocation()
        location?.stopUpdatingHeading()
        location = nil
        for q in healthQueries { store.stop(q) }
        healthQueries = []
        statusTimer?.invalidate()
        statusTimer = nil
        snapshotTimer?.cancel()
        snapshotTimer = nil
        let since = startedAt ?? Date()
        queue.async {
            for f in self.files.values { f.close() }
            self.files = [:]
            let id = self.segment
            self.segment = nil
            if let id { DispatchQueue.main.async { self.writeMeta(segment: id, start: since, end: Date()) } }
        }
        running = false
        startedAt = nil
    }

    /// closes the open chunks so everything so far goes to the iPhone now; the probe carries on in new chunks
    func shipOpenChunks() {
        queue.async { for f in self.files.values { f.close() } }
        Outbox.shared.resendAll()
    }

    /// a command from the iPhone's Lab tab (main thread); the reply says whether the probe runs
    func handle(_ command: String) -> [String: Any] {
        switch command {
        case ProbeLink.start: start()
        case ProbeLink.stop: stop()
        case ProbeLink.ship: shipOpenChunks()
        default: break
        }
        var reply: [String: Any] = [ProbeLink.runningKey: running]
        if let s = startedAt { reply[ProbeLink.sinceKey] = s.timeIntervalSince1970 }
        return reply
    }

    // MARK: writing (queue)

    private func write(_ stream: String, _ line: String, at t: Double) {
        guard let id = segment, let dir = directory else { return }
        let file: RotatingCSV
        if let f = files[stream] {
            file = f
        } else {
            file = RotatingCSV(directory: dir, prefix: stream, header: ProbeFormat.header(of: stream),
                               period: ProbeFormat.chunkSeconds, segment: id)
            files[stream] = file
        }
        file.append(line, at: t)
        counts[stream, default: 0] += 1
        lineCount += 1
    }

    private func note(_ text: String) {
        DispatchQueue.main.async {
            if !self.notes.contains(text) { self.notes.append(text) }
        }
    }

    private func unixTime(_ logTimestamp: TimeInterval) -> Double {
        RecordingFormat.unixTime(logTimestamp: logTimestamp, bootOffset: bootOffset)
    }

    private static func f(_ v: Double) -> String { String(format: "%.5f", v) }
    private static func opt(_ v: Double?, _ format: String = "%.3f") -> String { v.map { String(format: format, $0) } ?? "" }

    // MARK: motion

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            note("Device motion: not available")
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame
        if frames.contains(.xMagneticNorthZVertical) {
            frame = .xMagneticNorthZVertical
        } else if frames.contains(.xArbitraryCorrectedZVertical) {
            frame = .xArbitraryCorrectedZVertical
            note("Compass heading: not available (no magnetic reference frame)")
        } else {
            frame = .xArbitraryZVertical
            note("Compass heading: not available (no magnetic reference frame)")
        }
        motion.startDeviceMotionUpdates(using: frame, to: opQueue) { [weak self] data, error in
            guard let self else { return }
            if let error { self.note("Device motion: \(error.localizedDescription)"); return }
            guard let d = data else { return }
            self.handleMotion(d)
        }
    }

    /// runs on queue
    private func handleMotion(_ d: CMDeviceMotion) {
        motionSamples += 1
        if motionSamples % 3000 == 0 {
            bootOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        }
        let t = unixTime(d.timestamp)
        let a = d.userAcceleration, g = d.gravity, r = d.rotationRate
        let q = d.attitude.quaternion
        let m = d.magneticField
        var parts: [String] = [RecordingFormat.unix(t)]
        parts.reserveCapacity(22)
        for v in [a.x, a.y, a.z, g.x, g.y, g.z, r.x, r.y, r.z, q.w, q.x, q.y, q.z,
                  d.attitude.roll, d.attitude.pitch, d.attitude.yaw] {
            parts.append(Self.f(v))
        }
        parts.append(String(format: "%.1f", d.heading))
        parts.append(String(format: "%.2f", m.field.x))
        parts.append(String(format: "%.2f", m.field.y))
        parts.append(String(format: "%.2f", m.field.z))
        parts.append(String(Int(m.accuracy.rawValue)))
        write(ProbeFormat.motion, parts.joined(separator: ","), at: t)

        let tx = a.x + g.x, ty = a.y + g.y, tz = a.z + g.z
        let magnitude = (tx * tx + ty * ty + tz * tz).squareRoot()
        wave.append(Float(magnitude))
        if wave.count > 200 { wave.removeFirst(wave.count - 200) }
        if motionSamples % 10 == 0 {
            latest["motion.|a| g"] = magnitude
            latest["motion.user ax"] = a.x
            latest["motion.user ay"] = a.y
            latest["motion.user az"] = a.z
            latest["motion.gravity x"] = g.x
            latest["motion.gravity y"] = g.y
            latest["motion.gravity z"] = g.z
            latest["motion.rotation x"] = r.x
            latest["motion.rotation y"] = r.y
            latest["motion.rotation z"] = r.z
            latest["motion.roll"] = d.attitude.roll
            latest["motion.pitch"] = d.attitude.pitch
            latest["motion.yaw"] = d.attitude.yaw
            latest["motion.heading"] = d.heading
            latest["motion.magnetic x"] = m.field.x
            latest["motion.magnetic y"] = m.field.y
            latest["motion.magnetic z"] = m.field.z
            latest["motion.magnetic accuracy"] = Double(m.accuracy.rawValue)
        }
    }

    private func startBatched() {
        let accelOK = CMBatchedSensorManager.isAccelerometerSupported
        let motionOK = CMBatchedSensorManager.isDeviceMotionSupported
        if !accelOK { note("800 Hz accelerometer: not supported on this watch") }
        if !motionOK { note("200 Hz device motion: not supported on this watch") }
        guard accelOK || motionOK else { return }
        let manager = CMBatchedSensorManager()
        batched = manager
        if accelOK {
            let task = Task.detached(priority: .utility) { [weak self] in
                do {
                    for try await batch in manager.accelerometerUpdates() {
                        guard let self else { return }
                        self.queue.async { self.handleAccelBatch(batch) }
                    }
                } catch {
                    self?.note("800 Hz accelerometer: \(error.localizedDescription)")
                }
            }
            batchTasks.append(task)
        }
        if motionOK {
            let task = Task.detached(priority: .utility) { [weak self] in
                do {
                    for try await batch in manager.deviceMotionUpdates() {
                        guard let self else { return }
                        self.queue.async { self.handleMotionBatch(batch) }
                    }
                } catch {
                    self?.note("200 Hz device motion: \(error.localizedDescription)")
                }
            }
            batchTasks.append(task)
        }
    }

    private func stopBatched() {
        batched?.stopAccelerometerUpdates()
        batched?.stopDeviceMotionUpdates()
        for t in batchTasks { t.cancel() }
        batchTasks = []
        batched = nil
    }

    /// runs on queue
    private func handleAccelBatch(_ batch: [CMAccelerometerData]) {
        for d in batch {
            let t = unixTime(d.timestamp)
            let a = d.acceleration
            write(ProbeFormat.accel, "\(RecordingFormat.unix(t)),\(Self.f(a.x)),\(Self.f(a.y)),\(Self.f(a.z))", at: t)
        }
        latest["batched.accel batch size"] = Double(batch.count)
    }

    /// runs on queue
    private func handleMotionBatch(_ batch: [CMDeviceMotion]) {
        for d in batch {
            let t = unixTime(d.timestamp)
            let a = d.userAcceleration, g = d.gravity, r = d.rotationRate
            let q = d.attitude.quaternion
            var parts: [String] = [RecordingFormat.unix(t)]
            for v in [a.x, a.y, a.z, g.x, g.y, g.z, r.x, r.y, r.z, q.w, q.x, q.y, q.z] { parts.append(Self.f(v)) }
            write(ProbeFormat.fastMotion, parts.joined(separator: ","), at: t)
        }
        latest["batched.motion batch size"] = Double(batch.count)
    }

    // MARK: barometer, pedometer, activity

    private func startAltimeter() {
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: opQueue) { [weak self] data, error in
                guard let self else { return }
                if let error { self.note("Barometer: \(error.localizedDescription)"); return }
                guard let d = data else { return }
                let t = self.unixTime(d.timestamp)
                let p = d.pressure.doubleValue, alt = d.relativeAltitude.doubleValue
                self.write(ProbeFormat.pressure, "\(RecordingFormat.unix(t)),\(String(format: "%.4f", p)),\(String(format: "%.3f", alt))", at: t)
                self.latest["air.pressure kPa"] = p
                self.latest["air.relative altitude m"] = alt
            }
        } else {
            note("Barometer: not available")
        }
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: opQueue) { [weak self] data, error in
                guard let self else { return }
                if let error { self.note("Absolute altitude: \(error.localizedDescription)"); return }
                guard let d = data else { return }
                let t = Date().timeIntervalSince1970
                let line = "\(RecordingFormat.unix(t)),\(String(format: "%.2f", d.altitude)),\(String(format: "%.2f", d.accuracy)),\(String(format: "%.2f", d.precision))"
                self.write(ProbeFormat.altitude, line, at: t)
                self.latest["air.altitude m"] = d.altitude
                self.latest["air.altitude accuracy m"] = d.accuracy
            }
        } else {
            note("Absolute altitude: not available")
        }
    }

    private func startPedometer(since: Date) {
        guard CMPedometer.isStepCountingAvailable() else { note("Pedometer: not available"); return }
        pedometer.startUpdates(from: since) { [weak self] data, error in
            guard let self else { return }
            if let error { self.note("Pedometer: \(error.localizedDescription)"); return }
            guard let d = data else { return }
            let t = d.endDate.timeIntervalSince1970
            let distance = d.distance?.doubleValue
            let up = d.floorsAscended?.doubleValue
            let down = d.floorsDescended?.doubleValue
            let cadence = d.currentCadence?.doubleValue
            let pace = d.currentPace?.doubleValue
            let avgPace = d.averageActivePace?.doubleValue
            let steps = d.numberOfSteps.intValue
            let line = "\(RecordingFormat.unix(t)),\(steps),\(Self.opt(distance)),\(Self.opt(up, "%.0f")),\(Self.opt(down, "%.0f")),\(Self.opt(cadence)),\(Self.opt(pace)),\(Self.opt(avgPace))"
            self.queue.async {
                self.write(ProbeFormat.steps, line, at: t)
                self.latest["steps.since start"] = Double(steps)
                if let distance { self.latest["steps.distance m"] = distance }
                if let up { self.latest["steps.floors up"] = up }
                if let down { self.latest["steps.floors down"] = down }
                if let cadence { self.latest["steps.cadence /s"] = cadence }
                if let pace { self.latest["steps.pace s/m"] = pace }
            }
        }
        if CMPedometer.isPedometerEventTrackingAvailable() {
            pedometer.startEventUpdates { [weak self] event, _ in
                guard let self, let e = event else { return }
                let t = e.date.timeIntervalSince1970
                let kind = e.type == .pause ? "pause" : "resume"
                self.queue.async {
                    self.write(ProbeFormat.stepEvents, "\(RecordingFormat.unix(t)),\(kind)", at: t)
                    self.latest["steps.last event"] = kind
                }
            }
        }
    }

    /// today's totals from the pedometer's history (every minute, with the status)
    private func queryPedometerToday() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let start = Calendar.current.startOfDay(for: Date())
        pedometer.queryPedometerData(from: start, to: Date()) { [weak self] data, _ in
            guard let self, let d = data else { return }
            let steps = d.numberOfSteps.doubleValue
            let distance = d.distance?.doubleValue
            let floors = d.floorsAscended?.doubleValue
            self.queue.async {
                self.latest["steps.today"] = steps
                if let distance { self.latest["steps.today distance m"] = distance }
                if let floors { self.latest["steps.today floors up"] = floors }
            }
        }
    }

    private func startActivity() {
        guard CMMotionActivityManager.isActivityAvailable() else { note("Motion activity: not available"); return }
        activityManager.startActivityUpdates(to: opQueue) { [weak self] a in
            guard let self, let a else { return }
            let t = a.startDate.timeIntervalSince1970
            let flags: [Bool] = [a.stationary, a.walking, a.running, a.cycling, a.automotive, a.unknown]
            let line = "\(RecordingFormat.unix(t)),\(flags.map { $0 ? "1" : "0" }.joined(separator: ",")),\(a.confidence.rawValue)"
            self.write(ProbeFormat.activity, line, at: Date().timeIntervalSince1970)
            self.latest["activity.now"] = Self.activityName(a)
            self.latest["activity.confidence"] = Double(a.confidence.rawValue)
        }
    }

    /// one label for an activity update, which can set several flags at once (stationary in a car)
    private static func activityName(_ a: CMMotionActivity) -> String {
        if a.automotive { return "automotive" }
        if a.cycling { return "cycling" }
        if a.running { return "running" }
        if a.walking { return "walking" }
        if a.stationary { return "stationary" }
        return "unknown"
    }

    // MARK: location (main thread)

    private func startLocation() {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.distanceFilter = kCLDistanceFilterNone
        m.activityType = .other
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String], modes.contains("location") {
            m.allowsBackgroundLocationUpdates = true
        }
        location = m
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() }
        m.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            m.startUpdatingHeading()
        } else {
            note("Compass (Core Location): not available")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations {
            let t = l.timestamp.timeIntervalSince1970
            var parts: [String] = [RecordingFormat.unix(t)]
            parts.append(String(format: "%.7f", l.coordinate.latitude))
            parts.append(String(format: "%.7f", l.coordinate.longitude))
            parts.append(String(format: "%.2f", l.altitude))
            parts.append(String(format: "%.2f", l.ellipsoidalAltitude))
            parts.append(String(format: "%.1f", l.horizontalAccuracy))
            parts.append(String(format: "%.1f", l.verticalAccuracy))
            parts.append(String(format: "%.2f", l.speed))
            parts.append(String(format: "%.2f", l.speedAccuracy))
            parts.append(String(format: "%.1f", l.course))
            parts.append(String(format: "%.1f", l.courseAccuracy))
            parts.append(l.floor.map { String($0.level) } ?? "")
            let line = parts.joined(separator: ",")
            let lat = l.coordinate.latitude, lon = l.coordinate.longitude
            let acc = l.horizontalAccuracy, alt = l.altitude, speed = l.speed
            queue.async {
                self.write(ProbeFormat.location, line, at: t)
                self.latest["gps.latitude"] = lat
                self.latest["gps.longitude"] = lon
                self.latest["gps.accuracy m"] = acc
                self.latest["gps.altitude m"] = alt
                self.latest["gps.speed m/s"] = speed
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading
        let t = h.timestamp.timeIntervalSince1970
        let line = "\(RecordingFormat.unix(t)),\(String(format: "%.1f", h.magneticHeading)),\(String(format: "%.1f", h.trueHeading)),\(String(format: "%.1f", h.headingAccuracy)),\(String(format: "%.2f", h.x)),\(String(format: "%.2f", h.y)),\(String(format: "%.2f", h.z))"
        let magnetic = h.magneticHeading, accuracy = h.headingAccuracy
        queue.async {
            self.write(ProbeFormat.compass, line, at: t)
            self.latest["gps.compass deg"] = magnetic
            self.latest["gps.compass accuracy deg"] = accuracy
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        if s == .denied || s == .restricted { note("Location: not allowed for Sage") }
        if running && (s == .authorizedWhenInUse || s == .authorizedAlways) { manager.startUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        note("Location: \(error.localizedDescription)")
    }

    // MARK: Health

    static let quantityIDs: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .walkingHeartRateAverage, .heartRateVariabilitySDNN, .heartRateRecoveryOneMinute,
        .oxygenSaturation, .respiratoryRate, .appleSleepingWristTemperature, .bodyTemperature, .vo2Max,
        .stepCount, .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .swimmingStrokeCount, .flightsClimbed,
        .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime, .appleStandTime, .appleMoveTime,
        .environmentalAudioExposure, .headphoneAudioExposure, .environmentalSoundReduction, .timeInDaylight, .physicalEffort,
        .walkingSpeed, .walkingStepLength, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage,
        .stairAscentSpeed, .stairDescentSpeed, .sixMinuteWalkTestDistance, .appleWalkingSteadiness,
        .runningSpeed, .runningPower, .runningStrideLength, .runningVerticalOscillation, .runningGroundContactTime,
        .cyclingSpeed, .cyclingCadence, .cyclingPower, .underwaterDepth, .waterTemperature,
        .bodyMass, .height, .peripheralPerfusionIndex, .electrodermalActivity, .numberOfTimesFallen, .atrialFibrillationBurden
    ]

    static let categoryIDs: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis, .appleStandHour, .highHeartRateEvent, .lowHeartRateEvent, .irregularHeartRhythmEvent,
        .mindfulSession, .environmentalAudioExposureEvent, .headphoneAudioExposureEvent, .handwashingEvent,
        .lowCardioFitnessEvent, .appleWalkingSteadinessEvent
    ]

    private static var quantityTypes: [HKQuantityType] {
        quantityIDs.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
    }

    private static var sampleTypes: [HKSampleType] {
        var types: [HKSampleType] = quantityTypes
        for id in categoryIDs {
            if let t = HKObjectType.categoryType(forIdentifier: id) { types.append(t) }
        }
        types.append(HKSeriesType.heartbeat())
        types.append(HKObjectType.workoutType())
        return types
    }

    /// units to try when Health gives no preferred unit for a type
    private static let fallbackUnits: [HKUnit] = {
        let perMinute: HKUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let vo2: HKUnit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.minute()))
        let effort: HKUnit = HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.hour()))
        let speed: HKUnit = HKUnit.meter().unitDivided(by: HKUnit.second())
        let units: [HKUnit] = [perMinute, HKUnit.count(), HKUnit.meter(), HKUnit.kilocalorie(), HKUnit.percent(),
                               HKUnit.degreeCelsius(), HKUnit.secondUnit(with: .milli), HKUnit.minute(),
                               HKUnit.decibelAWeightedSoundPressureLevel(), vo2, effort, speed, HKUnit.gramUnit(with: .kilo),
                               HKUnit.watt(), HKUnit.siemen()]
        return units
    }()

    private static var shareTypes: Set<HKSampleType> {
        var s: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let t = HKObjectType.quantityType(forIdentifier: .heartRate) { s.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { s.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned) { s.insert(t) }
        return s
    }

    private func startHealth(since: Date, recovered: HKWorkoutSession?) {
        guard HKHealthStore.isHealthDataAvailable() else {
            note("Health: not available, so no workout session: the probe only runs while the app is in front")
            return
        }
        let read: Set<HKObjectType> = Set(Self.sampleTypes.map { $0 as HKObjectType })
        store.requestAuthorization(toShare: Self.shareTypes, read: read) { [weak self] _, error in
            guard let self else { return }
            if let error { self.note("Health access: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                guard self.running else { return }
                if self.store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingDenied {
                    self.note("Health: workouts are off for Sage (iPhone: Settings › Health › Data Access & Devices › Sage), so no workout session and no live heart rate")
                }
                if let s = recovered { self.adopt(s, start: since) } else { self.beginSession(start: since) }
                if self.highRate { self.startBatched() }
            }
            let quantities: Set<HKQuantityType> = Set(Self.quantityTypes)
            self.store.preferredUnits(for: quantities) { map, _ in
                self.queue.async { self.units = map }
                DispatchQueue.main.async { self.runHealthQueries(since: since) }
            }
        }
    }

    // MARK: workout session (main thread)

    private func beginSession(start: Date) {
        guard session == nil else { return }
        let config = WatchLaunch.configuration()
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            s.startActivity(with: start)
            b.beginCollection(withStart: start) { [weak self] _, error in
                if let error { self?.note("Workout: \(error.localizedDescription)") }
            }
            sessionRunning = true
        } catch {
            note("Workout session: \(error.localizedDescription)")
        }
    }

    private func adopt(_ s: HKWorkoutSession, start: Date) {
        let b = s.associatedWorkoutBuilder()
        b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: s.workoutConfiguration)
        s.delegate = self
        b.delegate = self
        session = s
        builder = b
        sessionRunning = true
    }

    private func endSession() {
        guard let s = session else { return }
        s.end()
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        let b = builder
        DispatchQueue.main.async {
            self.session = nil
            self.builder = nil
            self.sessionRunning = false
        }
        // nothing goes to Health: the session only keeps the probe alive
        b?.endCollection(withEnd: date) { _, _ in b?.discardWorkout() }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        note("Workout session: \(error.localizedDescription)")
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    /// the live workout's newest values (heart rate about every 5 s, energy), straight into the snapshot
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        var values: [(String, Double, String)] = []
        for type in collectedTypes {
            guard let q = type as? HKQuantityType, let stats = workoutBuilder.statistics(for: q) else { continue }
            let name = ProbeFormat.shortType(q.identifier)
            if let recent = stats.mostRecentQuantity() {
                for u in Self.fallbackUnits where recent.is(compatibleWith: u) {
                    values.append((name, recent.doubleValue(for: u), u.unitString))
                    break
                }
            }
            if let sum = stats.sumQuantity() {
                for u in Self.fallbackUnits where sum.is(compatibleWith: u) {
                    values.append((name + " total", sum.doubleValue(for: u), u.unitString))
                    break
                }
            }
        }
        queue.async {
            for (name, v, unit) in values {
                self.latest["workout.\(name)"] = v
                self.latest["unit.workout.\(name)"] = unit
            }
        }
    }

    /// one anchored query per type: everything from 24 h before the start, then every new sample (main thread)
    private func runHealthQueries(since: Date) {
        guard running else { return }
        let predicate = HKQuery.predicateForSamples(withStart: since.addingTimeInterval(-86_400), end: nil, options: [])
        for type in Self.sampleTypes {
            let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
                guard let self, let samples, !samples.isEmpty else { return }
                self.queue.async { self.logHealth(samples) }
            }
            let q = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
            q.updateHandler = handler
            healthQueries.append(q)
            store.execute(q)
        }
    }

    /// runs on queue
    private func logHealth(_ samples: [HKSample]) {
        let now = Date().timeIntervalSince1970
        let sorted = samples.sorted { $0.startDate < $1.startDate }
        for s in sorted {
            var value = ""
            var unit = ""
            var number: Double?
            var name = ProbeFormat.shortType(s.sampleType.identifier)
            if let q = s as? HKQuantitySample {
                if let u = unitFor(q) {
                    let v: Double = q.quantity.doubleValue(for: u)
                    number = v
                    value = String(format: "%.4f", v)
                    unit = u.unitString
                } else {
                    value = ProbeFormat.field(q.quantity.description)
                }
            } else if let c = s as? HKCategorySample {
                number = Double(c.value)
                value = String(c.value)
                unit = "category"
            } else if let series = s as? HKHeartbeatSeriesSample {
                number = Double(series.count)
                value = String(series.count)
                unit = "beats"
                name = "HeartbeatSeries"
                if seenSeries.insert(series.uuid).inserted {
                    DispatchQueue.main.async { self.readBeats(series) }
                }
            } else if let w = s as? HKWorkout {
                number = w.duration
                value = String(format: "%.0f", w.duration)
                unit = "s"
                name = "Workout\(w.workoutActivityType.rawValue)"
            }
            let source = ProbeFormat.field(s.sourceRevision.source.name)
            let device = ProbeFormat.field(s.device?.model ?? "")
            let line = "\(RecordingFormat.unix(s.startDate)),\(RecordingFormat.unix(s.endDate)),\(name),\(value),\(ProbeFormat.field(unit)),\(source),\(device)"
            // rotation by the moment of writing: 24 h of backfill must not open a chunk per old sample
            write(ProbeFormat.health, line, at: now)
            if let number {
                latest["hk.\(name)"] = number
                latest["unit.hk.\(name)"] = unit
            }
        }
    }

    /// runs on queue
    private func unitFor(_ q: HKQuantitySample) -> HKUnit? {
        if let u = units[q.quantityType], q.quantity.is(compatibleWith: u) { return u }
        for u in Self.fallbackUnits where q.quantity.is(compatibleWith: u) { return u }
        return nil
    }

    /// every beat of one heartbeat series (main thread: starts the query)
    private func readBeats(_ series: HKHeartbeatSeriesSample) {
        let start = series.startDate.timeIntervalSince1970
        let q = HKHeartbeatSeriesQuery(heartbeatSeries: series) { [weak self] _, offset, gap, _, error in
            guard let self, error == nil else { return }
            let t = start + offset
            let line = "\(RecordingFormat.unix(t)),\(RecordingFormat.unix(start)),\(String(format: "%.4f", offset)),\(gap ? 1 : 0)"
            self.queue.async { self.write(ProbeFormat.beats, line, at: Date().timeIntervalSince1970) }
        }
        store.execute(q)
    }

    // MARK: status and snapshots

    private func startTimers() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.logStatus() }
        logStatus()
        queryPedometerToday()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sendSnapshot() }
        timer.resume()
        snapshotTimer?.cancel()
        snapshotTimer = timer
    }

    /// main thread: the watch itself, every 5 s
    private var statusTicks = 0
    private func logStatus() {
        statusTicks += 1
        if statusTicks % 12 == 0 { queryPedometerToday() }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let battery = Double(device.batteryLevel)
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        default: batteryState = "unknown"
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let waterLock = device.isWaterLockEnabled
        let wrist = device.wristLocation == .left ? "left" : "right"
        let crown = device.crownOrientation == .left ? "left" : "right"
        let appState: String
        switch WKApplication.shared().applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        let reachable = WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
        let uptime = ProcessInfo.processInfo.systemUptime
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let freeBytes = (attrs?[.systemFreeSize] as? NSNumber)?.doubleValue ?? -1
        let freeMB = freeBytes >= 0 ? freeBytes / 1_048_576 : -1
        let recorder = sessionRunning
        let pending = Outbox.shared.pending
        let t = Date().timeIntervalSince1970
        let offset = t - uptime
        queue.async {
            self.bootOffset = offset
            var parts: [String] = [RecordingFormat.unix(t), String(format: "%.2f", battery), batteryState, thermal]
            parts.append(lowPower ? "1" : "0")
            parts.append(waterLock ? "1" : "0")
            parts.append(wrist)
            parts.append(crown)
            parts.append(appState)
            parts.append(reachable ? "1" : "0")
            parts.append(String(format: "%.0f", uptime))
            parts.append(String(format: "%.0f", freeMB))
            parts.append(recorder ? "1" : "0")
            parts.append(String(pending))
            parts.append(String(self.lineCount))
            self.write(ProbeFormat.device, parts.joined(separator: ","), at: t)
            self.latest["watch.battery %"] = battery * 100
            self.latest["watch.battery state"] = batteryState
            self.latest["watch.thermal"] = thermal
            self.latest["watch.low power"] = lowPower ? "on" : "off"
            self.latest["watch.water lock"] = waterLock ? "on" : "off"
            self.latest["watch.wrist"] = "\(wrist), crown \(crown)"
            self.latest["watch.app state"] = appState
            self.latest["watch.free MB"] = freeMB
            self.latest["watch.uptime h"] = uptime / 3600
            self.latest["watch.workout session"] = recorder ? "running" : "off"
            self.latest["watch.files waiting"] = Double(pending)
        }
    }

    /// runs on queue, once a second
    private func sendSnapshot() {
        var snap: [String: Any] = latest
        let now = Date().timeIntervalSince1970
        snap["t"] = now
        snap["probe.lines total"] = Double(lineCount)
        for (stream, n) in counts { snap["lines.\(ProbeFormat.title(of: stream))"] = Double(n) }
        let waveData = ProbeLink.packWave(Array(wave.suffix(50)))
        let total = lineCount
        let perStream = counts
        DispatchQueue.main.async {
            self.totalLines = total
            self.streamLines = perStream
            guard WCSession.isSupported() else { return }
            let s = WCSession.default
            guard s.activationState == .activated, s.isReachable else { return }
            s.sendMessage([ProbeLink.snapshotKey: snap, ProbeLink.waveKey: waveData], replyHandler: nil, errorHandler: nil)
            self.sentSnapshots += 1
        }
    }

    /// the segment's description: when, which watch, and which sensors it has (main thread)
    private func writeMeta(segment id: String, start: Date, end: Date?) {
        let device = WKInterfaceDevice.current()
        // built step by step: Xcode 26's type checker times out on large mixed literals
        var sensors: [String: Bool] = [:]
        sensors["accelerometer"] = motion.isAccelerometerAvailable
        sensors["gyroscope"] = motion.isGyroAvailable
        sensors["device_motion"] = motion.isDeviceMotionAvailable
        sensors["magnetic_reference"] = CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
        sensors["batched_accelerometer"] = CMBatchedSensorManager.isAccelerometerSupported
        sensors["batched_device_motion"] = CMBatchedSensorManager.isDeviceMotionSupported
        sensors["barometer"] = CMAltimeter.isRelativeAltitudeAvailable()
        sensors["absolute_altitude"] = CMAltimeter.isAbsoluteAltitudeAvailable()
        sensors["steps"] = CMPedometer.isStepCountingAvailable()
        sensors["distance"] = CMPedometer.isDistanceAvailable()
        sensors["floors"] = CMPedometer.isFloorCountingAvailable()
        sensors["cadence"] = CMPedometer.isCadenceAvailable()
        sensors["pace"] = CMPedometer.isPaceAvailable()
        sensors["pedometer_events"] = CMPedometer.isPedometerEventTrackingAvailable()
        sensors["activity"] = CMMotionActivityManager.isActivityAvailable()
        sensors["compass"] = CLLocationManager.headingAvailable()
        sensors["health"] = HKHealthStore.isHealthDataAvailable()
        let width = Int(device.screenBounds.width), height = Int(device.screenBounds.height)
        var meta: [String: Any] = [:]
        meta["segment"] = id
        meta["probe"] = true
        meta["start"] = start.timeIntervalSince1970
        meta["watch"] = device.model
        meta["watch_name"] = device.name
        meta["watchos"] = device.systemVersion
        meta["screen"] = "\(width)x\(height) @\(device.screenScale)x"
        meta["water_resistance_raw"] = device.waterResistanceRating.rawValue
        meta["app"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        meta["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        meta["time_zone"] = TimeZone.current.identifier
        meta["high_rate"] = highRate
        meta["gps"] = gps
        meta["sensors"] = sensors
        if let end {
            meta["end"] = end.timeIntervalSince1970
            meta["notes"] = notes
        }
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }
        Outbox.shared.shipData(data, name: RecordingFormat.metaName, segment: id)
    }
}
