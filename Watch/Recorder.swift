import Foundation
import HealthKit
import CoreMotion
import WatchKit

extension Notification.Name {
    /// posted on the main queue whenever the recorder starts or stops
    static let recorderStateChanged = Notification.Name("SageRecorderStateChanged")
}

/// Keeps Sage running around the clock and records while it runs.
///
/// A Mind & Body workout session is the one thing watchOS lets run indefinitely in the background, so it keeps the
/// face in front on every wrist raise. While it runs, the recorder writes:
/// - heart rate from the workout session (about every 5 s instead of every few minutes),
/// - a one-second motion summary (movement and wrist position),
/// - optionally the raw accelerometer (10–50 Hz), with or without the gyroscope,
/// - air pressure from the barometer, and once a minute battery and charging state.
/// Files rotate on the clock and travel to the iPhone through `Outbox`. Nothing is written to Apple Health unless
/// "Save workout to Health" is on; by default the session is discarded when it ends.
final class Recorder: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    static let shared = Recorder()

    @Published private(set) var isRunning = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var bpm: Int?
    @Published private(set) var lastBeatAt: Date?
    @Published private(set) var heartSamples = 0
    @Published private(set) var motionSamples = 0
    @Published private(set) var lastError: String?

    /// keep a session running whenever Sage is open (survives charging, restarts and crashes)
    @Published var keepRunning: Bool { didSet { UserDefaults.standard.set(keepRunning, forKey: Keys.keepRunning) } }
    /// raw accelerometer rate; 0 = summary only (the summary itself always samples at least 10 Hz)
    @Published var rawMotionHz: Int { didSet { UserDefaults.standard.set(rawMotionHz, forKey: Keys.rawHz) } }
    /// also record the gyroscope (rotation rate) with the raw stream
    @Published var gyroscope: Bool { didSet { UserDefaults.standard.set(gyroscope, forKey: Keys.gyro) } }
    /// save the session as a workout in Apple Health when it ends (off: the session is discarded, Health stays untouched)
    @Published var saveWorkout: Bool { didSet { UserDefaults.standard.set(saveWorkout, forKey: Keys.save) } }

    /// 10 Hz feed of |acceleration| in g, delivered on the main queue
    var motionTap: ((Double) -> Void)?
    /// one summary per second of motion (spread and gravity), on the main queue: the live sleep detectors
    var secondTap: ((MotionSecond) -> Void)?
    /// every heart-rate sample (time, bpm) as it is written, on the main queue
    var heartTap: ((Double, Double) -> Void)?
    /// called on the main queue when a deliberate shake is felt while `armShake(true)`
    var onShake: (() -> Void)?

    /// the running recording's segment (events from the alarm are filed with it)
    var segmentID: String? { segment }

    private enum Keys {
        static let keepRunning = "rec.keepRunning", rawHz = "rec.rawHz", gyro = "rec.gyro", save = "rec.saveWorkout"
        static let segment = "rec.segment", started = "rec.started"
    }

    static let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var starting = false
    private var recovering = false
    private var segment: String?

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private var statusTimer: Timer?
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        q.name = "sage.recorder.motion"
        return q
    }()
    private let heartQueue = DispatchQueue(label: "sage.recorder.heart", qos: .utility)

    // owned by motionQueue
    private var summaryFile: RotatingCSV?
    private var rawFile: RotatingCSV?
    private var pressureFile: RotatingCSV?
    private var summarizer = MotionSummarizer()
    private var bootOffset: TimeInterval = 0
    private var motionCount = 0
    private var tapStride = 1
    private var tapCount = 0
    private var liveSum = (0.0, 0.0, 0.0)        // averaged into the 10 Hz feed for the iPhone's live breathing
    private var liveCount = 0
    private var shakeArmed = false
    private var shake = ShakeDetector()
    // owned by heartQueue
    private var heartFile: RotatingCSV?
    private var statusFile: RotatingCSV?
    private var activityFile: RotatingCSV?
    private var loggedHeart = Set<Int64>()        // sample start times (ms) already written
    private var heartCount = 0
    private var heartQuery: HKAnchoredObjectQuery?

    private override init() {
        let d = UserDefaults.standard
        keepRunning = d.object(forKey: Keys.keepRunning) as? Bool ?? true
        rawMotionHz = d.object(forKey: Keys.rawHz) as? Int ?? 50
        gyroscope = d.object(forKey: Keys.gyro) as? Bool ?? false
        saveWorkout = d.object(forKey: Keys.save) as? Bool ?? false
        super.init()
    }

    static var liveRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Live", isDirectory: true)
    }

    private static var shareTypes: Set<HKSampleType> {
        var s: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let t = HKQuantityType.quantityType(forIdentifier: .heartRate) { s.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { s.insert(t) }
        return s
    }

    private static var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [HKObjectType.workoutType()]
        for id in [HKQuantityTypeIdentifier.heartRate, .activeEnergyBurned, .stepCount] {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { s.insert(t) }
        }
        return s
    }

    // MARK: start / stop

    /// Starts a recording run, unless one is already running.
    func start() {
        guard !isRunning, !starting, !recovering, session == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else { setError("Health is not available on this watch."); return }
        starting = true
        store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes) { [weak self] ok, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.starting = false; self.setError("Health access: \(error.localizedDescription)"); return }
                self.beginSession()
            }
        }
    }

    private func beginSession() {
        defer { starting = false }
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        let s: HKWorkoutSession
        do {
            s = try HKWorkoutSession(healthStore: store, configuration: config)
        } catch {
            setError("Could not start: \(error.localizedDescription)")
            return
        }
        let b = s.associatedWorkoutBuilder()
        b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
        s.delegate = self
        b.delegate = self
        session = s
        builder = b

        let now = Date()
        let id = RecordingFormat.segmentID(for: now)
        UserDefaults.standard.set(id, forKey: Keys.segment)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Keys.started)
        Outbox.shared.shipLeftovers(in: Self.liveRoot, except: id)
        openFiles(segment: id)
        writeMeta(segment: id, start: now, end: nil)

        s.startActivity(with: now)
        b.beginCollection(withStart: now) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.setError("Heart rate: \(error.localizedDescription)") } }
        }
        startMotion()
        startPressureAndStatus()
        startHeartQuery(since: now)
        markRunning(since: now)
    }

    /// Ends the run; the workout is saved to (or discarded from) Health and the last chunks are sent.
    func stop() {
        guard let s = session else { finishLocal(end: Date()); return }
        s.end()
    }

    /// After watchOS relaunched Sage in the middle of a run (crash, update, reboot), take the session back.
    func recover() {
        recovering = true
        store.recoverActiveWorkoutSession { [weak self] recovered, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.recovering = false
                guard let s = recovered, self.session == nil else {
                    if self.keepRunning && self.session == nil { self.start() }
                    return
                }
                let b = s.associatedWorkoutBuilder()
                b.dataSource = HKLiveWorkoutDataSource(healthStore: self.store, workoutConfiguration: s.workoutConfiguration)
                s.delegate = self
                b.delegate = self
                self.session = s
                self.builder = b
                let d = UserDefaults.standard
                let id = d.string(forKey: Keys.segment) ?? RecordingFormat.segmentID(for: Date())
                let since = (d.object(forKey: Keys.started) as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
                self.openFiles(segment: id)
                self.startMotion()
                self.startPressureAndStatus()
                self.startHeartQuery(since: since)
                self.markRunning(since: since)
            }
        }
    }

    // MARK: files

    private func openFiles(segment id: String) {
        segment = id
        let dir = Self.liveRoot.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rawHeader = gyroscope ? RecordingFormat.rawGyroHeader : RecordingFormat.rawHeader
        let wantsRaw = rawMotionHz > 0
        motionQueue.addOperation {
            self.summarizer = MotionSummarizer()
            let period = RecordingFormat.chunkSeconds
            self.summaryFile = RotatingCSV(directory: dir, prefix: RecordingFormat.summaryPrefix, header: RecordingFormat.summaryHeader,
                                           period: period, segment: id)
            self.rawFile = wantsRaw ? RotatingCSV(directory: dir, prefix: RecordingFormat.rawPrefix, header: rawHeader, period: period, segment: id) : nil
            self.pressureFile = RotatingCSV(directory: dir, prefix: RecordingFormat.pressurePrefix, header: RecordingFormat.pressureHeader,
                                            period: period, segment: id)
        }
        heartQueue.async {
            let period = RecordingFormat.chunkSeconds
            self.heartFile = RotatingCSV(directory: dir, prefix: RecordingFormat.heartPrefix, header: RecordingFormat.heartHeader,
                                         period: period, segment: id)
            self.statusFile = RotatingCSV(directory: dir, prefix: RecordingFormat.statusPrefix, header: RecordingFormat.statusHeader,
                                          period: period, segment: id)
            self.activityFile = RotatingCSV(directory: dir, prefix: RecordingFormat.activityPrefix, header: RecordingFormat.activityHeader,
                                            period: period, segment: id)
        }
    }

    /// Closes the open chunks so they go to the iPhone now ("Send now"); recording carries on in new chunks.
    func shipOpenChunks() {
        motionQueue.addOperation {
            self.summaryFile?.close()
            self.rawFile?.close()
            self.pressureFile?.close()
        }
        heartQueue.async {
            self.heartFile?.close()
            self.statusFile?.close()
            self.activityFile?.close()
        }
    }

    /// One activity change (written at once: these lines are few and precious).
    func logActivity(at t: Double, _ kind: ActivityKind, confidence: Int) {
        let line = "\(RecordingFormat.unix(t)),\(kind.rawValue),\(confidence)"
        heartQueue.async {
            self.activityFile?.append(line, at: t)
            self.activityFile?.flush()
        }
    }

    /// Feeds |a| at the full sampling rate to the shake detector while armed (only while the alarm rings).
    func armShake(_ on: Bool) {
        motionQueue.addOperation {
            self.shakeArmed = on
            self.shake.reset()
        }
    }

    private func closeFiles() {
        motionQueue.addOperation {
            if let line = self.summarizer.flush() { self.summaryFile?.append(line, at: Date().timeIntervalSince1970) }
            self.summaryFile?.close()
            self.rawFile?.close()
            self.pressureFile?.close()
            self.summaryFile = nil
            self.rawFile = nil
            self.pressureFile = nil
        }
        heartQueue.async {
            self.heartFile?.close()
            self.statusFile?.close()
            self.activityFile?.close()
            self.heartFile = nil
            self.statusFile = nil
            self.activityFile = nil
        }
    }

    private func writeMeta(segment id: String, start: Date, end: Date?) {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        var meta: [String: Any] = [
            "segment": id,
            "start": start.timeIntervalSince1970,
            "raw_motion_hz": rawMotionHz,
            "barometer": CMAltimeter.isRelativeAltitudeAvailable() ? Self.motionAuthorization : "unavailable",
            "gyroscope": gyroscope,
            "save_workout": saveWorkout,
            "watch": device.model,
            "watchos": device.systemVersion,
            "app": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "time_zone": TimeZone.current.identifier
        ]
        let battery = Double(device.batteryLevel)
        if let end {
            meta["end"] = end.timeIntervalSince1970
            meta["battery_end"] = battery
            meta["heart_samples"] = heartSamples
            meta["motion_samples"] = motionSamples
        } else {
            meta["battery_start"] = battery
        }
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }
        Outbox.shared.shipData(data, name: RecordingFormat.metaName, segment: id)
    }

    // MARK: motion

    private func startMotion() {
        let wantsRaw = rawMotionHz > 0
        let hz = max(10, wantsRaw ? rawMotionHz : 10)
        let withGyro = wantsRaw && gyroscope && motion.isDeviceMotionAvailable
        motionQueue.addOperation {
            self.tapStride = max(1, hz / 10)
            self.tapCount = 0
            self.bootOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        }
        if withGyro {
            motion.deviceMotionUpdateInterval = 1.0 / Double(hz)
            motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                let a = d.userAcceleration, g = d.gravity, r = d.rotationRate
                self.handleSample(time: d.timestamp, x: a.x + g.x, y: a.y + g.y, z: a.z + g.z, rotation: (r.x, r.y, r.z), hz: hz)
            }
        } else if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 1.0 / Double(hz)
            motion.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                self.handleSample(time: d.timestamp, x: d.acceleration.x, y: d.acceleration.y, z: d.acceleration.z, rotation: nil, hz: hz)
            }
        }
    }

    private func stopMotion() {
        motion.stopAccelerometerUpdates()
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func startPressureAndStatus() {
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: motionQueue) { [weak self] data, error in
                if let error {
                    DispatchQueue.main.async { self?.setError("Pressure: \(error.localizedDescription) (check Settings › Privacy › Motion & Fitness)") }
                    return
                }
                guard let self, let d = data else { return }
                let t = d.timestamp + self.bootOffset
                self.pressureFile?.append("\(RecordingFormat.unix(t)),\(String(format: "%.4f", d.pressure.doubleValue)),\(String(format: "%.2f", d.relativeAltitude.doubleValue))", at: t)
            }
        }
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.logStatus() }
        logStatus()
    }

    private func logStatus() {
        let device = WKInterfaceDevice.current()
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "unknown"
        }
        let line = "\(RecordingFormat.unix(Date())),\(String(format: "%.2f", Double(device.batteryLevel))),\(state),\(bpm.map(String.init) ?? ""),\(heartSamples),\(motionSamples)"
        let now = Date().timeIntervalSince1970
        heartQueue.async { self.statusFile?.append(line, at: now) }
    }

    /// runs on motionQueue
    private func handleSample(time: TimeInterval, x: Double, y: Double, z: Double, rotation: (Double, Double, Double)?, hz: Int) {
        motionCount += 1
        if motionCount % (hz * 60) == 0 {
            // sensor time does not tick while the watch sleeps deeply; re-anchor it to the wall clock once a minute
            bootOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        }
        let t = time + bootOffset
        let f = RecordingFormat.f4
        if let raw = rawFile {
            if let r = rotation {
                raw.append("\(RecordingFormat.unix(t)),\(f(x)),\(f(y)),\(f(z)),\(f(r.0)),\(f(r.1)),\(f(r.2))", at: t)
            } else {
                raw.append("\(RecordingFormat.unix(t)),\(f(x)),\(f(y)),\(f(z))", at: t)
            }
        }
        if let line = summarizer.add(t: t, x: x, y: y, z: z) {
            summaryFile?.append(line, at: t)
            if let second = summarizer.lastSecond { DispatchQueue.main.async { self.secondTap?(second) } }
        }
        if shakeArmed && shake.add(t: t, magnitude: (x * x + y * y + z * z).squareRoot()) {
            DispatchQueue.main.async { self.onShake?() }
        }

        liveSum.0 += x; liveSum.1 += y; liveSum.2 += z
        liveCount += 1
        tapCount += 1
        if tapCount >= tapStride {
            tapCount = 0
            let m = (x * x + y * y + z * z).squareRoot()
            DispatchQueue.main.async { self.motionTap?(m) }
            let n = Double(liveCount)
            LiveStreamer.shared.add(x: liveSum.0 / n, y: liveSum.1 / n, z: liveSum.2 / n)
            liveSum = (0, 0, 0)
            liveCount = 0
        }
        if motionCount % (hz * 10) == 0 {
            let c = motionCount
            DispatchQueue.main.async { self.motionSamples = c }
        }
    }

    // MARK: HKLiveWorkoutBuilderDelegate

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let hr = HKQuantityType.quantityType(forIdentifier: .heartRate), collectedTypes.contains(hr),
              let stats = workoutBuilder.statistics(for: hr),
              let quantity = stats.mostRecentQuantity(),
              let interval = stats.mostRecentQuantityDateInterval() else { return }
        let value = quantity.doubleValue(for: Self.bpmUnit)
        heartQueue.async { self.logHeart(start: interval.start, end: interval.end, bpm: value) }
    }

    /// runs on heartQueue; both the builder and the anchored query feed it, each sample is written once
    private func logHeart(start: Date, end: Date, bpm value: Double) {
        let key = Int64((start.timeIntervalSince1970 * 1000).rounded())
        guard loggedHeart.insert(key).inserted else { return }
        if loggedHeart.count > 20_000 { loggedHeart.removeAll(keepingCapacity: true); loggedHeart.insert(key) }
        heartFile?.append("\(RecordingFormat.unix(start)),\(RecordingFormat.unix(end)),\(String(format: "%.1f", value))",
                          at: start.timeIntervalSince1970)
        heartCount += 1
        if heartCount % 12 == 0 { heartFile?.flush() }
        let count = heartCount
        let sampleTime = start.timeIntervalSince1970
        DispatchQueue.main.async {
            self.heartTap?(sampleTime, value)
            if self.lastBeatAt.map({ end >= $0 }) ?? true {
                self.bpm = Int(value.rounded())
                self.lastBeatAt = end
            }
            self.heartSamples = count
        }
    }

    /// Every heart-rate sample saved while the run lasts, including the batches watchOS delivers late while the
    /// screen is off (the builder's statistics only expose the newest one of a batch).
    private func startHeartQuery(since: Date) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        if let q = heartQuery { store.stop(q) }
        let predicate = HKQuery.predicateForSamples(withStart: since.addingTimeInterval(-60), end: nil, options: [])
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let self, let quantities = samples as? [HKQuantitySample], !quantities.isEmpty else { return }
            let rows = quantities.map { ($0.startDate, $0.endDate, $0.quantity.doubleValue(for: Self.bpmUnit)) }.sorted { $0.0 < $1.0 }
            self.heartQueue.async { for r in rows { self.logHeart(start: r.0, end: r.1, bpm: r.2) } }
        }
        let q = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler
        heartQuery = q
        store.execute(q)
    }

    private func stopHeartQuery() {
        if let q = heartQuery { store.stop(q) }
        heartQuery = nil
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    // MARK: HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended else { return }
        let save = saveWorkout
        guard let b = builder else { DispatchQueue.main.async { self.finishLocal(end: date) }; return }
        b.endCollection(withEnd: date) { [weak self] _, _ in
            if save {
                b.finishWorkout { _, _ in }
            } else {
                b.discardWorkout()
            }
            DispatchQueue.main.async { self?.finishLocal(end: date) }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.setError("Session: \(error.localizedDescription)") }
    }

    // MARK: state

    private func finishLocal(end: Date) {
        stopMotion()
        stopHeartQuery()
        closeFiles()
        if let id = segment, let since = startedAt { writeMeta(segment: id, start: since, end: end) }
        UserDefaults.standard.removeObject(forKey: Keys.segment)
        UserDefaults.standard.removeObject(forKey: Keys.started)
        session = nil
        builder = nil
        segment = nil
        let wasRunning = isRunning
        isRunning = false
        startedAt = nil
        bpm = nil
        if wasRunning { NotificationCenter.default.post(name: .recorderStateChanged, object: self) }
    }

    private func markRunning(since: Date) {
        startedAt = since
        isRunning = true
        lastError = nil
        ActivityMonitor.shared.logCurrent()
        NotificationCenter.default.post(name: .recorderStateChanged, object: self)
    }

    /// Motion & Fitness permission as plain words, for segment.json (the barometer needs it; the accelerometer does not)
    private static var motionAuthorization: String {
        switch CMAltimeter.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private func setError(_ text: String) {
        lastError = text
    }
}
