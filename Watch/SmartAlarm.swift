import Foundation
import WatchKit
import CoreMotion

/// Silent smart alarm.
///
/// Nap: from an hour before the planned nap until 90 minutes after it (or for 90 minutes after "Nap now") the watch
/// looks for the moment you fall asleep (`OnsetDetector`). From then on it wakes you at the first sign the cycle has
/// ended (`WakeRule`: stirring or the heart rate rising) between `napEarliest` and `napLatest` minutes after falling
/// asleep (70 and 100 by default), and at `napLatest` at the latest. No sleep found: no alarm.
///
/// Night: inside the plan's window (06:00–06:30) at the first sign of a cycle ending, at 06:30 at the latest.
///
/// The taps follow the vibration settings and stop after `ringMinutes`, with the Stop button, with a hard shake of
/// the wrist (works with the screen dark, e.g. in Sleep Focus) or from the iPhone. Everything is logged (`EventLog`).
///
/// While the recorder runs, Sage runs anyway (workout session) and all of this happens inline on the recorder's
/// motion and heart feeds. Without the recorder only the fixed windows work, through a smart-alarm runtime session.
final class SmartAlarm: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    static let shared = SmartAlarm()

    enum StopReason: String { case button, shake, iphone, timeout, ended }

    @Published private(set) var ringing = false
    @Published private(set) var ringingBlock: Plan.Block?
    /// a test from the iPhone is vibrating
    @Published private(set) var testing = false
    /// a delayed test is waiting to start
    @Published private(set) var testStartsAt: Date?
    /// what the alarm is doing, in a few words (recorder controls)
    @Published private(set) var status = ""
    /// the nap you are in: when you fell asleep and the wake window
    @Published private(set) var nap: NapState?

    struct NapState: Codable, Equatable {
        var onset: Date
        var earliest: Date
        var latest: Date
    }

    // inline mode (recorder running)
    private var onsetDetector: OnsetDetector?
    private var onsetPurpose: Plan.Block?
    private var watchUntil: Date?                  // nap watch ends here (no sleep found: no alarm)
    private var nightOnset: Date?
    private var rule: WakeRule?
    private var ruleBlock: Plan.Block?
    private var ruleWindowEnd: Date?
    private var heartBuffer: [(Double, Double)] = []
    private var timers: [Timer] = []

    // session mode (recorder off)
    private var session: WKExtendedRuntimeSession?
    private var sessionWindow: Plan.WakeWindow?
    private let motion = CMMotionManager()
    private var sessionSecond = SecondAccumulator()
    private var sessionShake = ShakeDetector()

    // vibration pattern (the real alarm and the test share one player)
    private var patternTimer: Timer?
    private var patternRun = 0
    private var testDelay: Timer?
    private var ringTimeout: Timer?

    private enum Keys {
        static let handledNight = "alarm.handledNight", handledNap = "alarm.handledNap", nap = "alarm.nap", manualNap = "alarm.manualNap"
    }

    /// a block is not armed again until this time (after it rang, was stopped, or its watch ended)
    private var handledNight: Date {
        get { UserDefaults.standard.object(forKey: Keys.handledNight) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: Keys.handledNight) }
    }
    private var handledNap: Date {
        get { UserDefaults.standard.object(forKey: Keys.handledNap) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: Keys.handledNap) }
    }
    /// "Nap now": watch for sleep until this time
    private var manualNapUntil: Date? {
        get { UserDefaults.standard.object(forKey: Keys.manualNap) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.manualNap) }
    }
    private var savedNap: NapState? {
        get { (UserDefaults.standard.data(forKey: Keys.nap)).flatMap { try? JSONDecoder().decode(NapState.self, from: $0) } }
        set {
            if let v = newValue, let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: Keys.nap) }
            else { UserDefaults.standard.removeObject(forKey: Keys.nap) }
        }
    }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: .recorderStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleNext()
        }
        Recorder.shared.onShake = { [weak self] in
            guard let self else { return }
            if self.ringing { self.stop(.shake) } else if self.testing { self.stopTest() }
        }
    }

    // MARK: planning

    /// Arms whatever comes next. Safe to call any time (app start, becoming active, recorder changes, settings).
    func scheduleNext(now: Date = .now) {
        if ringing { return }
        let settings = AlarmSettings.load().clamped()
        timers.forEach { $0.invalidate() }
        timers.removeAll()

        if Recorder.shared.isRunning {
            if let s = session, s.state == .running { return }      // a window is being watched already; let it finish
            if let s = session { session = nil; sessionWindow = nil; s.invalidate() }
            planInline(now: now, settings: settings)
            armRuleTimers()
        } else {
            if let s = session, s.state == .running { armRuleTimers(); updateStatus(now: now); return }
            tearDownInline()
            planSession(now: now)
        }
        updateTaps()
        updateStatus(now: now)
    }

    private func planInline(now: Date, settings: AlarmSettings) {
        // a nap in progress (also after a relaunch in the middle of it)
        if let n = savedNap, n.latest > now, n.latest > handledNap {
            nap = n
            if rule == nil || ruleBlock != .nap { startRule(.nap, onset: n.onset, opens: n.earliest, closes: n.latest) }
        } else if savedNap != nil {
            savedNap = nil
            nap = nil
        }

        // nap: look for the moment you fall asleep
        if nap == nil {
            let watch = napWatch(now: now)
            if let w = watch, w.start <= now {
                if onsetPurpose != .nap { beginOnsetWatch(.nap, until: w.end) }
                watchUntil = w.end
                at(w.end) { [weak self] in self?.napWatchEnded() }
            } else if let w = watch {
                at(w.start) { [weak self] in self?.scheduleNext() }
            }
        }

        // night: the window, and the moment you fall asleep before it (for the heart baseline and the record)
        let night = Plan.nextWakeWindow(after: max(now, handledNight), block: .night)
        if let o = nightOnset, o < night.start.addingTimeInterval(-12 * 3600) { nightOnset = nil }    // last night's
        if night.start <= now {
            if rule == nil || ruleBlock != .night {
                startRule(.night, onset: nightOnset ?? night.start.addingTimeInterval(-4 * 3600), opens: night.start, closes: night.end)
            }
        } else {
            at(night.start) { [weak self] in self?.scheduleNext() }
            let watchFrom = night.start.addingTimeInterval(-8 * 3600)
            if watchFrom <= now, nightOnset == nil, onsetDetector == nil { beginOnsetWatch(.night, until: night.start) }
            else if watchFrom > now { at(watchFrom) { [weak self] in self?.scheduleNext() } }
        }
        _ = settings
    }

    /// today's (or a manual) nap watch, if it has not ended or been handled
    private func napWatch(now: Date) -> DateInterval? {
        if let until = manualNapUntil, until > now { return DateInterval(start: now.addingTimeInterval(-1), end: until) }
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        let start = day.addingTimeInterval((Plan.nap.onset - 60) * 60)
        let end = day.addingTimeInterval((Plan.nap.onset + 90) * 60)
        guard end > now, end > handledNap else { return nil }
        return DateInterval(start: start, end: end)
    }

    func napNow() {
        guard !ringing else { return }
        manualNapUntil = Date().addingTimeInterval(90 * 60)
        handledNap = .distantPast
        savedNap = nil
        nap = nil
        onsetDetector = nil
        onsetPurpose = nil
        EventLog.log(.napArmed, "manual")
        scheduleNext()
    }

    func cancelNap() {
        manualNapUntil = nil
        handledNap = Date().addingTimeInterval(4 * 3600)
        savedNap = nil
        nap = nil
        if ruleBlock == .nap { rule = nil; ruleBlock = nil; ruleWindowEnd = nil }
        if onsetPurpose == .nap { onsetDetector = nil; onsetPurpose = nil }
        EventLog.log(.napCancelled)
        scheduleNext()
    }

    private func napWatchEnded() {
        guard onsetPurpose == .nap, nap == nil else { return }
        onsetDetector = nil
        onsetPurpose = nil
        watchUntil = nil
        manualNapUntil = nil
        handledNap = Date()
        scheduleNext()
    }

    private func beginOnsetWatch(_ block: Plan.Block, until: Date) {
        var d = OnsetDetector()
        for (t, b) in heartBuffer { d.addHeart(t: t, bpm: b) }
        onsetDetector = d
        onsetPurpose = block
        watchUntil = until
    }

    private func startRule(_ block: Plan.Block, onset: Date, opens: Date, closes: Date) {
        var r = WakeRule(onset: onset.timeIntervalSince1970, opens: opens.timeIntervalSince1970, closes: closes.timeIntervalSince1970)
        for (t, b) in heartBuffer { r.remember(t: t, bpm: b) }
        rule = r
        ruleBlock = block
        ruleWindowEnd = closes
        armRuleTimers()
    }

    /// the window opening and the latest wake as timers (the latest wake must not depend on a motion second arriving);
    /// re-armed whenever the plan is redone, since that clears all timers
    private func armRuleTimers() {
        guard let r = rule, let block = ruleBlock else { return }
        let opens = Date(timeIntervalSince1970: r.opens), closes = Date(timeIntervalSince1970: r.closes)
        if opens > Date() {
            at(opens) { [weak self] in self?.windowOpened(block) }
        } else {
            windowOpened(block)
        }
        at(closes) { [weak self] in
            guard let self, self.ruleBlock == block, !self.ringing else { return }
            self.ring(block, reason: WakeRule.Reason.latest.rawValue)
        }
    }

    private var openedLogged: Set<String> = []
    private func windowOpened(_ block: Plan.Block) {
        let key = "\(block.rawValue)-\(Int(rule?.opens ?? 0))"
        guard openedLogged.insert(key).inserted else { return }
        EventLog.log(.windowOpen, block.rawValue)
        if let end = ruleWindowEnd { Task { @MainActor in LampAutomation.shared.sunrise(until: end) } }
        updateStatus(now: Date())
    }

    private func onsetFound(_ t: Double) {
        guard let purpose = onsetPurpose else { return }
        let onset = Date(timeIntervalSince1970: t)
        onsetDetector = nil
        onsetPurpose = nil
        EventLog.log(.asleep, purpose.rawValue, at: onset)
        switch purpose {
        case .nap:
            let s = AlarmSettings.load().clamped()
            var n = NapState(onset: onset, earliest: onset.addingTimeInterval(s.napEarliest * 60), latest: onset.addingTimeInterval(s.napLatest * 60))
            if n.latest <= Date() { n.latest = Date().addingTimeInterval(60) }     // found very late: still wake gently
            savedNap = n
            nap = n
            manualNapUntil = nil
            watchUntil = nil
            startRule(.nap, onset: n.onset, opens: n.earliest, closes: n.latest)
        case .night:
            nightOnset = onset
        }
        updateTaps()
        updateStatus(now: Date())
    }

    /// a timer on the main run loop (the recorder's workout session keeps Sage running for it)
    private func at(_ date: Date, _ action: @escaping () -> Void) {
        let t = Timer(fire: max(date, Date().addingTimeInterval(0.5)), interval: 0, repeats: false) { _ in action() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func tearDownInline() {
        onsetDetector = nil
        onsetPurpose = nil
        rule = nil
        ruleBlock = nil
        ruleWindowEnd = nil
        watchUntil = nil
        updateTaps()
    }

    /// the recorder's feeds are only taken while something listens
    private func updateTaps() {
        let r = Recorder.shared
        if onsetDetector != nil || rule != nil {
            r.secondTap = { [weak self] s in self?.second(s) }
            r.heartTap = { [weak self] t, b in self?.beat(t, b) }
        } else {
            r.secondTap = nil
            r.heartTap = { [weak self] t, b in self?.keepHeart(t, b) }
        }
    }

    private func keepHeart(_ t: Double, _ bpm: Double) {
        heartBuffer.append((t, bpm))
        let cut = t - 3 * 3600
        if let i = heartBuffer.firstIndex(where: { $0.0 >= cut }), i > 0 { heartBuffer.removeFirst(i) }
    }

    private func second(_ s: MotionSecond) {
        if var d = onsetDetector {
            let found = d.add(s)
            onsetDetector = d
            if let t = found { onsetFound(t) }
        }
        if var r = rule, let block = ruleBlock, !ringing {
            let reason = r.second(s)
            rule = r
            if let reason { ring(block, reason: reason.rawValue) }
        }
    }

    private func beat(_ t: Double, _ bpm: Double) {
        keepHeart(t, bpm)
        if var d = onsetDetector { d.addHeart(t: t, bpm: bpm); onsetDetector = d }
        if var r = rule, let block = ruleBlock, !ringing {
            let reason = r.beat(t: t, bpm: bpm)
            rule = r
            if let reason { ring(block, reason: reason.rawValue) }
        }
    }

    private func updateStatus(now: Date) {
        let f = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        if ringing { status = "Ringing"; return }
        if let n = nap { status = "Nap: asleep since \(f(n.onset)) · wake \(f(n.earliest))–\(f(n.latest))"; return }
        if onsetPurpose == .nap, let until = watchUntil { status = "Nap: waiting for you to fall asleep (until \(f(until)))"; return }
        if ruleBlock == .night, let end = ruleWindowEnd { status = "Morning window open until \(f(end))"; return }
        if !Recorder.shared.isRunning {
            if let w = sessionWindow { status = "Next wake window \(f(w.start))–\(f(w.end)) (fixed: Record is off)" } else { status = "" }
            return
        }
        let night = Plan.nextWakeWindow(after: max(now, handledNight), block: .night)
        status = "Next: nap watch from \(Plan.fmt(Plan.nap.onset - 60)) · morning window \(f(night.start))–\(f(night.end))"
    }

    // MARK: session mode (recorder off): the fixed windows

    private func planSession(now: Date) {
        if let s = session, s.state == .scheduled || s.state == .running { return }
        let night = Plan.nextWakeWindow(after: max(now, handledNight), block: .night)
        let napWindow = Plan.nextWakeWindow(after: max(now, handledNap), block: .nap)
        let window = napWindow.start < night.start ? napWindow : night
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        session = s
        sessionWindow = window
        if window.start <= now { s.start() } else { s.start(at: window.start) }
    }

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { self.listenInSession() }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async {
            if let w = self.sessionWindow { self.ring(w.block, reason: "expiring") }     // never let the session end silently
        }
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        DispatchQueue.main.async {
            guard self.session === extendedRuntimeSession else { return }
            self.motion.stopAccelerometerUpdates()
            if self.ringing { self.finishRinging(.ended) }
            self.session = nil
            self.sessionWindow = nil
            self.rule = nil
            self.ruleBlock = nil
        }
    }

    private func listenInSession() {
        guard let w = sessionWindow else { return }
        rule = WakeRule(onset: w.start.timeIntervalSince1970 - 2 * 3600, opens: w.start.timeIntervalSince1970, closes: w.end.timeIntervalSince1970)
        ruleBlock = w.block
        ruleWindowEnd = w.end
        EventLog.log(.windowOpen, "\(w.block.rawValue) (fixed)")
        let end = w.end
        Task { @MainActor in LampAutomation.shared.sunrise(until: end) }
        at(w.end) { [weak self] in
            guard let self, !self.ringing, self.sessionWindow == w else { return }
            self.ring(w.block, reason: WakeRule.Reason.latest.rawValue)
        }
        guard motion.isAccelerometerAvailable else { return }     // no motion: the deadline alone wakes you
        sessionSecond = SecondAccumulator()
        motion.accelerometerUpdateInterval = 1.0 / 25
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            let t = Date().timeIntervalSince1970
            let m = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            if self.ringing {
                if self.sessionShake.add(t: t, magnitude: m) { self.stop(.shake) }
                return
            }
            if let s = self.sessionSecond.add(t: t, x: a.x, y: a.y, z: a.z) { self.second(s) }
        }
    }

    // MARK: ringing

    private func ring(_ block: Plan.Block, reason: String) {
        guard !ringing else { return }
        stopTest()
        let settings = AlarmSettings.load().clamped()
        ringing = true
        ringingBlock = block
        rule = nil
        ruleBlock = nil
        onsetDetector = nil
        onsetPurpose = nil
        updateTaps()
        EventLog.log(.ring, "\(block.rawValue) \(reason)")
        Task { @MainActor in LampAutomation.shared.alarmRang() }
        updateStatus(now: Date())
        ringTimeout?.invalidate()
        ringTimeout = Timer.scheduledTimer(withTimeInterval: settings.ringSeconds, repeats: false) { [weak self] _ in self?.stop(.timeout) }

        if let s = session, s.state == .running {
            sessionShake.reset()
            let begin = Date()
            let ramp = settings.rampSeconds
            s.notifyUser(hapticType: Self.haptic(settings.level(at: 0, ramp: ramp))) { next in
                next.pointee = Self.haptic(settings.level(at: Date().timeIntervalSince(begin), ramp: ramp))
                return settings.gap
            }
            return
        }
        Recorder.shared.armShake(true)
        startPattern(settings, ramp: settings.rampSeconds, length: settings.ringSeconds + 5) {}
    }

    /// Stops the ringing alarm (Stop button, shake, iPhone, timeout).
    func stop(_ how: StopReason = .button) {
        guard ringing else { return }
        finishRinging(how)
        if let s = session { s.invalidate() }
        scheduleNext()
    }

    private func finishRinging(_ how: StopReason) {
        let block = ringingBlock
        ringing = false
        ringingBlock = nil
        ringTimeout?.invalidate()
        ringTimeout = nil
        stopPattern()
        Recorder.shared.armShake(false)
        motion.stopAccelerometerUpdates()
        EventLog.log(.stop, how.rawValue)
        let now = Date()
        switch block {
        case .nap?:
            handledNap = max(handledNap, now.addingTimeInterval(3600))
            savedNap = nil
            nap = nil
            manualNapUntil = nil
        case .night?:
            handledNight = max(handledNight, Plan.nextWakeWindow(after: now.addingTimeInterval(-3600), block: .night).end)
            nightOnset = nil
        case nil:
            break
        }
        WKInterfaceDevice.current().play(.stop)
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

    // MARK: messages from the iPhone

    /// Answers a message from the iPhone's alarm screen; runs on the main queue.
    func handle(_ message: [String: Any]) -> [String: Any] {
        switch message[AlarmLink.commandKey] as? String ?? "" {
        case AlarmLink.test:
            return test(AlarmSettings(dictionary: message[AlarmLink.settingsKey] as? [String: Any]))
        case AlarmLink.preview:
            guard !ringing else { return reply(false, "The alarm is ringing right now.") }
            let level = (message[AlarmLink.levelKey] as? NSNumber)?.intValue ?? 0
            WKInterfaceDevice.current().play(Self.haptic(min(max(level, 0), AlarmSettings.levels.upperBound)))
            return reply(true, "\(AlarmLevel.name(level)) played on the watch.")
        case AlarmLink.stop:
            if ringing {
                stop(.iphone)
                return reply(true, "Alarm stopped.")
            }
            let was = testing || testStartsAt != nil
            stopTest()
            return reply(true, was ? "Test stopped." : "Nothing was ringing.")
        case AlarmLink.napNow:
            guard Recorder.shared.isRunning else { return reply(false, "Record is off on the watch: the nap alarm needs it to feel when you fall asleep.") }
            napNow()
            return reply(true, "Nap armed: the watch wakes you one cycle after you fall asleep.")
        default:
            return [:]
        }
    }

    private func test(_ settings: AlarmSettings) -> [String: Any] {
        guard !ringing else { return reply(false, "The alarm is ringing right now.") }
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
        return reply(true, "Vibrating on the watch for \(Int(s.testSeconds)) s: \(climb). Shake hard to stop it.\(note)")
    }

    private func beginTest(_ s: AlarmSettings) {
        testDelay?.invalidate(); testDelay = nil
        testStartsAt = nil
        guard !ringing else { return }
        testing = true
        EventLog.log(.testStart)
        Recorder.shared.armShake(true)
        startPattern(s, ramp: s.testRamp, length: s.testSeconds) { [weak self] in self?.stopTest() }
    }

    /// stops a running test, or cancels one that is waiting; never touches the real alarm
    func stopTest() {
        testDelay?.invalidate(); testDelay = nil
        testStartsAt = nil
        if testing {
            testing = false
            stopPattern()
            if !ringing { Recorder.shared.armShake(false) }
            EventLog.log(.testStop)
        }
    }

    private func reply(_ ok: Bool, _ text: String) -> [String: Any] {
        [AlarmLink.okKey: ok, AlarmLink.textKey: text, LiveLink.recordingKey: Recorder.shared.isRunning, AlarmLink.ringingKey: ringing]
    }
}

/// Seconds of motion from a stream of accelerometer samples (session mode, where the recorder does not run).
struct SecondAccumulator {
    private var second = Int.min
    private var n = 0
    private var sum = 0.0, sum2 = 0.0, sx = 0.0, sy = 0.0, sz = 0.0

    mutating func add(t: Double, x: Double, y: Double, z: Double) -> MotionSecond? {
        let s = Int(t.rounded(.down))
        var out: MotionSecond? = nil
        if s != second {
            if n > 1 {
                let c = Double(n), mean = sum / c
                let sd = max(0, (sum2 - c * mean * mean) / (c - 1)).squareRoot()
                out = MotionSecond(t: Double(second), sd: sd, gx: sx / c, gy: sy / c, gz: sz / c)
            }
            second = s; n = 0; sum = 0; sum2 = 0; sx = 0; sy = 0; sz = 0
        }
        let m = (x * x + y * y + z * z).squareRoot()
        n += 1; sum += m; sum2 += m * m; sx += x; sy += y; sz += z
        return out
    }
}
