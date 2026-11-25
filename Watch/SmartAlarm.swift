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
    @Published private(set) var ringing = false
    @Published private(set) var scheduledWindow: Plan.WakeWindow?

    private var session: WKExtendedRuntimeSession?
    private let motion = CMMotionManager()
    private var magnitudes: [Double] = []
    private var deadline: Timer?

    // inline mode
    private var inline = false
    private var openTimer: Timer?
    private var hapticTimer: Timer?
    private var haptics = 0

    /// a window that has been rung or dismissed is not armed again
    private var handledUntil = Date.distantPast

    /// movement threshold: standard deviation of |acceleration| (g) over the last 20 s
    static let restlessness = 0.018
    static let windowSeconds = 20.0
    static let sampleRate = 10.0
    /// inline haptics: one tap every 2.5 s for at most ten minutes
    static let hapticInterval = 2.5
    static let hapticLimit = 240

    override init() {
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
        hapticTimer?.invalidate(); hapticTimer = nil
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
        hapticTimer?.invalidate(); hapticTimer = nil
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
        if inline {
            ringing = true
            Recorder.shared.motionTap = nil
            deadline?.invalidate()
            haptics = 0
            WKInterfaceDevice.current().play(.notification)
            hapticTimer?.invalidate()
            hapticTimer = Timer.scheduledTimer(withTimeInterval: Self.hapticInterval, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                self.haptics += 1
                WKInterfaceDevice.current().play(.directionUp)
                if self.haptics >= Self.hapticLimit { t.invalidate() }
            }
            return
        }
        guard let s = session, s.state == .running else { return }
        ringing = true
        motion.stopAccelerometerUpdates()
        deadline?.invalidate()
        // a soft tap, then rising taps every 2.5 s until stopped (the system caps the repeats)
        s.notifyUser(hapticType: .notification) { next in
            next.pointee = .directionUp
            return 2.5
        }
    }

    private func finish() {
        motion.stopAccelerometerUpdates()
        deadline?.invalidate(); deadline = nil
        ringing = false
        session = nil
    }
}
