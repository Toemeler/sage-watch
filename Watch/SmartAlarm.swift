import Foundation
import WatchKit
import CoreMotion

/// Silent smart alarm for both sleep blocks.
///
/// At the start of the next wake window (18:15 for the nap, 06:00 for the night) the alarm listens for restlessness,
/// the wrist moving as sleep turns light. The first restless stretch inside the window starts the haptic taps; if none
/// comes, the taps start at the window's end (18:30 / 06:30), so the plan's "awake by" always holds.
///
/// Two ways to stay awake for the window:
/// - while the recorder runs, Sage is already running through its workout session, so the alarm simply uses the
///   recorder's motion feed and plays the haptics itself ("inline");
/// - otherwise a smart-alarm extended runtime session opens at the window start, as before.
final class SmartAlarm: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    static let shared = SmartAlarm()

    @Published private(set) var ringing = false
    @Published private(set) var scheduledWindow: Plan.WakeWindow?
    /// a test from the iPhone is vibrating
    @Published private(set) var testing = false
    /// a delayed test is waiting to start
    @Published private(set) var testStartsAt: Date?

    private var session: WKExtendedRuntimeSession?
    private let motion = CMMotionManager()
    private var magnitudes: [Double] = []
    private var deadline: Timer?

    // inline mode
    private var inline = false
    private var openTimer: Timer?

    // vibration pattern (the real alarm and the test share one player)
    private var patternTimer: Timer?
    private var patternRun = 0
    private var testDelay: Timer?

    /// a window that has been rung or dismissed is not armed again
    private var handledUntil = Date.distantPast

    /// movement threshold: standard deviation of |acceleration| (g) over the last 20 s
    static let restlessness = 0.018
    static let windowSeconds = 20.0
    static let sampleRate = 10.0
    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: .recorderStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.recorderChanged()
        }
    }

    // MARK: scheduling

    func scheduleNext(now: Date = .now) {
        if ringing { return }
        if Recorder.shared.isRunning { scheduleInline(now: now); return }
        if let s = session, s.state == .scheduled || s.state == .running { return }
        let window = Plan.nextWakeWindow(after: max(now, handledUntil))
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        session = s
        scheduledWindow = window
        if window.start <= now {
            s.start()                     // the window is already open (app launched inside it)
        } else {
            s.start(at: window.start)
        }
    }

    func stop() {
        handledUntil = max(handledUntil, scheduledWindow?.end ?? Date())
        stopPattern()
        if inline {
            cancelInline()
        } else {
            session?.invalidate()
            finish()
        }
        scheduleNext()
    }

    /// The recorder started or stopped: move the armed window to the other mechanism.
    private func recorderChanged() {
        if ringing { return }
        if Recorder.shared.isRunning {
            if let s = session, s.state == .running { return }      // a window is being watched already; let it finish
            if let s = session { session = nil; s.invalidate() }
            scheduledWindow = nil
            scheduleInline(now: Date())
        } else {
            cancelInline()
            scheduleNext()
        }
    }

    // MARK: inline (inside the recorder's workout session)

    private func scheduleInline(now: Date) {
        if inline, scheduledWindow != nil { return }
        inline = true
        let window = Plan.nextWakeWindow(after: max(now, handledUntil))
        scheduledWindow = window
        openTimer?.invalidate()
        let delay = window.start.timeIntervalSince(now)
        if delay <= 0 {
            listenInline()
        } else {
            openTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.listenInline() }
        }
    }

    private func listenInline() {
        guard inline, let window = scheduledWindow else { return }
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: max(window.end.timeIntervalSinceNow, 1), repeats: false) { [weak self] _ in
            self?.ring()
        }
        magnitudes.removeAll()
        Recorder.shared.motionTap = { [weak self] m in self?.feed(m) }
    }

    private func cancelInline() {
        openTimer?.invalidate(); openTimer = nil
        deadline?.invalidate(); deadline = nil
        if ringing { stopPattern() }
        if inline { Recorder.shared.motionTap = nil }
        inline = false
        ringing = false
        scheduledWindow = nil
        magnitudes.removeAll()
    }

    // MARK: session

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { self.listen() }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { self.ring() }    // failsafe: never let the session end silently
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        DispatchQueue.main.async {
            if self.session === extendedRuntimeSession { self.finish() }
        }
    }

    // MARK: listening

    private func listen() {
        guard let window = scheduledWindow else { return }
        let end = max(window.end.timeIntervalSinceNow, 1)
        deadline = Timer.scheduledTimer(withTimeInterval: end, repeats: false) { [weak self] _ in self?.ring() }
        guard motion.isAccelerometerAvailable else { return }      // no motion: the deadline alone wakes you
        magnitudes.removeAll()
        motion.accelerometerUpdateInterval = 1 / Self.sampleRate
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            self.feed(sqrt(a.x * a.x + a.y * a.y + a.z * a.z))
        }
    }

    /// one |acceleration| sample at 10 Hz
    private func feed(_ magnitude: Double) {
        magnitudes.append(magnitude)
        let keep = Int(Self.windowSeconds * Self.sampleRate)
        if magnitudes.count > keep { magnitudes.removeFirst(magnitudes.count - keep) }
        if magnitudes.count == keep && Self.standardDeviation(magnitudes) > Self.restlessness { ring() }
    }

    static func standardDeviation(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        return sqrt(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1))
    }

    // MARK: waking

    private func ring() {
        guard !ringing else { return }
        let settings = AlarmSettings.load()
        if inline {
            stopTest()
            ringing = true
            Recorder.shared.motionTap = nil
            deadline?.invalidate()
            // the pattern set on the iPhone, climbing to full strength over its ramp, for at most ten minutes
            startPattern(settings, ramp: settings.rampSeconds, length: AlarmSettings.alarmSeconds) {}
            return
        }
        guard let s = session, s.state == .running else { return }
        stopTest()
        ringing = true
        motion.stopAccelerometerUpdates()
        deadline?.invalidate()
        // the system plays one haptic per repeat here, so the strength ramp and the gap apply but not the taps per pulse
        let begin = Date()
        let ramp = settings.rampSeconds
        s.notifyUser(hapticType: Self.haptic(settings.level(at: 0, ramp: ramp))) { next in
            next.pointee = Self.haptic(settings.level(at: Date().timeIntervalSince(begin), ramp: ramp))
            return settings.clamped().gap
        }
    }

    // MARK: vibration pattern

    /// the system haptic for each strength, softest first
    static func haptic(_ level: Int) -> WKHapticType {
        switch AlarmLevel(rawValue: level) ?? .alert {
        case .click: return .click
        case .tap: return .directionUp
        case .knock: return .start
        case .alert: return .notification
        case .buzz: return .failure
        }
    }

    /// Pulses every `effectiveGap` seconds, each a burst of `taps` taps, climbing from the start to the peak strength
    /// over `ramp` seconds; ends after `length` seconds and then calls `done`.
    private func startPattern(_ settings: AlarmSettings, ramp: Double, length: Double, done: @escaping () -> Void) {
        stopPattern()
        patternRun += 1
        let run = patternRun
        let begin = Date()
        let s = settings.clamped()
        let pulse = { [weak self] in
            guard let self, self.patternRun == run else { return }
            let type = Self.haptic(s.level(at: Date().timeIntervalSince(begin), ramp: ramp))
            for offset in s.tapOffsets {
                if offset == 0 { WKInterfaceDevice.current().play(type); continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                    guard let self, self.patternRun == run else { return }
                    WKInterfaceDevice.current().play(type)
                }
            }
        }
        pulse()
        patternTimer = Timer.scheduledTimer(withTimeInterval: s.effectiveGap, repeats: true) { [weak self] t in
            guard let self, self.patternRun == run else { t.invalidate(); return }
            if Date().timeIntervalSince(begin) >= length - 0.05 {
                self.stopPattern()
                done()
                return
            }
            pulse()
        }
    }

    private func stopPattern() {
        patternRun += 1          // cancels taps still queued inside a burst
        patternTimer?.invalidate()
        patternTimer = nil
    }

    // MARK: test (from the iPhone)

    /// Answers a message from the iPhone's alarm screen; runs on the main queue.
    func handle(_ message: [String: Any]) -> [String: Any] {
        switch message[AlarmLink.commandKey] as? String ?? "" {
        case AlarmLink.test:
            return test(AlarmSettings(dictionary: message[AlarmLink.settingsKey] as? [String: Any]))
        case AlarmLink.preview:
            guard !ringing else { return reply(false, "The real alarm is ringing right now.") }
            let level = (message[AlarmLink.levelKey] as? NSNumber)?.intValue ?? 0
            WKInterfaceDevice.current().play(Self.haptic(min(max(level, 0), AlarmSettings.levels.upperBound)))
            return reply(true, "\(AlarmLevel.name(level)) played on the watch.")
        case AlarmLink.stop:
            let was = testing || testStartsAt != nil
            stopTest()
            return reply(true, was ? "Test stopped." : "No test was running.")
        default:
            return [:]
        }
    }

    private func test(_ settings: AlarmSettings) -> [String: Any] {
        guard !ringing else { return reply(false, "The real alarm is ringing right now.") }
        stopTest()
        settings.save()
        let s = settings.clamped()
        let recording = Recorder.shared.isRunning
        let delay = s.testDelayMinutes * 60
        if delay > 0 {
            guard recording else {
                return reply(false, "Record is off on the watch. A delayed test needs Sage to keep running: long-press the face and turn on Record, then try again.")
            }
            let at = Date().addingTimeInterval(delay)
            testStartsAt = at
            testDelay = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.beginTest(s) }
            return reply(true, "Test alarm set for \(at.formatted(date: .omitted, time: .shortened)) on the watch (\(Int(s.testSeconds)) s).")
        }
        beginTest(s)
        let climb = s.startLevel == s.peakLevel
            ? AlarmLevel.name(s.peakLevel)
            : "\(AlarmLevel.name(s.startLevel)) → \(AlarmLevel.name(s.peakLevel))"
        let note = recording ? "" : " Record is off, so it only vibrates while Sage is on screen."
        return reply(true, "Vibrating on the watch for \(Int(s.testSeconds)) s: \(climb).\(note)")
    }

    private func beginTest(_ s: AlarmSettings) {
        testDelay?.invalidate(); testDelay = nil
        testStartsAt = nil
        guard !ringing else { return }
        testing = true
        startPattern(s, ramp: s.testRamp, length: s.testSeconds) { [weak self] in self?.testing = false }
    }

    /// stops a running test, or cancels one that is waiting; never touches the real alarm
    func stopTest() {
        testDelay?.invalidate(); testDelay = nil
        testStartsAt = nil
        if testing {
            testing = false
            stopPattern()
        }
    }

    private func reply(_ ok: Bool, _ text: String) -> [String: Any] {
        [AlarmLink.okKey: ok, AlarmLink.textKey: text, LiveLink.recordingKey: Recorder.shared.isRunning]
    }

    private func finish() {
        motion.stopAccelerometerUpdates()
        deadline?.invalidate(); deadline = nil
        ringing = false
        session = nil
    }
}
