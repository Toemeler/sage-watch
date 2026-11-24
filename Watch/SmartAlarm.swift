import Foundation
import WatchKit
import CoreMotion

/// Silent smart alarm for both sleep blocks.
///
/// A smart-alarm extended runtime session opens at the start of the next wake window (18:15 for the nap,
/// 06:00 for the night). While it runs, the accelerometer listens for restlessness, the wrist moving as sleep turns light.
/// The first restless stretch inside the window starts the haptic taps; if none comes, the taps start at the window's end
/// (18:30 / 06:30), so the plan's "awake by" always holds.
final class SmartAlarm: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    @Published private(set) var ringing = false
    @Published private(set) var scheduledWindow: Plan.WakeWindow?

    private var session: WKExtendedRuntimeSession?
    private let motion = CMMotionManager()
    private var magnitudes: [Double] = []
    private var deadline: Timer?

    /// movement threshold: standard deviation of |acceleration| (g) over the last 20 s
    static let restlessness = 0.018
    static let windowSeconds = 20.0
    static let sampleRate = 10.0

    // MARK: scheduling

    func scheduleNext(now: Date = .now) {
        if let s = session, s.state == .scheduled || s.state == .running { return }
        let window = Plan.nextWakeWindow(after: now)
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
        session?.invalidate()
        finish()
        scheduleNext()
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
            self.magnitudes.append(sqrt(a.x * a.x + a.y * a.y + a.z * a.z))
            let keep = Int(Self.windowSeconds * Self.sampleRate)
            if self.magnitudes.count > keep { self.magnitudes.removeFirst(self.magnitudes.count - keep) }
            if self.magnitudes.count == keep && Self.standardDeviation(self.magnitudes) > Self.restlessness { self.ring() }
        }
    }

    static func standardDeviation(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        return sqrt(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count - 1))
    }

    // MARK: waking

    private func ring() {
        guard !ringing, let s = session, s.state == .running else { return }
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
