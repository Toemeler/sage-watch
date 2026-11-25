import Foundation
import WatchConnectivity
import HealthKit

/// The iPhone half of live breathing: asks the watch for its motion stream while the screen is open and runs the
/// breathing detector on what arrives.
final class LiveBreathing: ObservableObject {
    static let shared = LiveBreathing()

    @Published private(set) var wave: [Double] = []
    @Published private(set) var peaks: [Int] = []
    @Published private(set) var rate: Double?
    @Published private(set) var status = "Connecting to the watch…"
    @Published private(set) var receiving = false

    private var detector = BreathingDetector()
    private var timer: Timer?
    private var active = false
    private var lastSample: Date?
    private var recorderOff = false
    private var lastWake = Date.distantPast
    private let health = HKHealthStore()

    func start() {
        active = true
        detector = BreathingDetector()
        wave = []; peaks = []; rate = nil; lastSample = nil; recorderOff = false; receiving = false
        status = "Connecting to the watch…"
        lastWake = .distantPast
        ask(on: true)
        if !WCSession.default.isReachable { wakeWatch() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        active = false
        timer?.invalidate()
        timer = nil
        ask(on: false)
    }

    /// called on the main thread with one message of packed samples from the watch
    func receive(_ data: Data) {
        guard active else { return }
        for v in LiveLink.unpack(data) { detector.add(x: v.0, y: v.1, z: v.2) }
        lastSample = Date()
        receiving = true
        wave = detector.wave
        peaks = detector.peaks
        rate = detector.breathsPerMinute
        if detector.moving {
            status = "Hold still: your arm moved."
        } else if rate != nil {
            status = "Breathing found"
        } else if wave.count < BreathingDetector.minimum {
            status = "Listening… stay still for 15 s."
        } else {
            status = "Looking for a steady rhythm…"
        }
    }

    private func tick() {
        ask(on: true)
        if let t = lastSample, Date().timeIntervalSince(t) < 3 { return }
        receiving = false
        if !WCSession.default.isReachable || recorderOff {
            wakeWatch()
            status = "Waking Sage on the watch…"
        } else {
            status = "Waiting for the watch…"
        }
    }

    /// Opens Sage on the watch with a live-breathing workout configuration, so it keeps running (and streaming) with
    /// the watch screen off. At most every 30 s.
    private func wakeWatch() {
        guard active, Date().timeIntervalSince(lastWake) > 30 else { return }
        lastWake = Date()
        health.startWatchApp(with: WatchLaunch.configuration(live: true)) { ok, error in
            DispatchQueue.main.async {
                guard self.active, !ok, !self.receiving else { return }
                self.status = "Couldn't open Sage on the watch: \(error?.localizedDescription ?? "unknown error"). Keep it close and unlocked."
            }
        }
    }

    private func ask(on: Bool) {
        guard WCSession.isSupported() else { status = "This iPhone has no paired watch."; return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage([LiveLink.commandKey: LiveLink.breathing, LiveLink.onKey: on], replyHandler: { reply in
            let off = reply[LiveLink.recordingKey] as? Bool == false
            DispatchQueue.main.async { self.recorderOff = off }
        }, errorHandler: nil)
    }
}
