import Foundation
import WatchConnectivity
import WatchKit

/// Streams the wrist's motion (10 times a second, averaged from the recorder's samples) to the iPhone while its
/// live breathing screen is open. The iPhone repeats its request every few seconds; without one for 20 s the stream
/// stops by itself, so a closed or crashed iPhone app never keeps the watch sending.
final class LiveStreamer {
    static let shared = LiveStreamer()

    private let queue = DispatchQueue(label: "sage.live", qos: .userInitiated)
    private var on = false
    private var lastRequest = Date.distantPast
    private var buffer: [Float] = []

    // main queue: keeping Sage running while the iPhone watches
    private var startedRecorder = false
    private var awakeTimer: Timer?

    /// Main queue. While the live screen is open Sage must keep running with the screen dimmed or off, which only a
    /// workout session allows: if the recorder is off, start it for the live view and stop it again 25 s after the last
    /// request (unless Record was switched on meanwhile).
    func keepAwake(_ on: Bool) {
        awakeTimer?.invalidate()
        awakeTimer = nil
        let recorder = Recorder.shared
        if on {
            WKApplication.shared().isFrontmostTimeoutExtended = true
            if !recorder.isRunning {
                if !recorder.keepRunning { startedRecorder = true }
                recorder.start()
            }
            awakeTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in self?.keepAwake(false) }
        } else {
            WKApplication.shared().isFrontmostTimeoutExtended = false
            if startedRecorder && !recorder.keepRunning { recorder.stop() }
            startedRecorder = false
        }
    }

    func request(on: Bool) {
        queue.async {
            self.on = on
            self.lastRequest = Date()
            self.buffer.removeAll()
        }
    }

    /// one averaged sample in g; called from the recorder's motion queue
    func add(x: Double, y: Double, z: Double) {
        queue.async {
            guard self.on else { return }
            if Date().timeIntervalSince(self.lastRequest) > 20 {
                self.on = false
                self.buffer.removeAll()
                return
            }
            self.buffer += [Float(x), Float(y), Float(z)]
            guard self.buffer.count >= 15 else { return }        // 5 samples = half a second per message
            let data = LiveLink.pack(self.buffer)
            self.buffer.removeAll()
            let session = WCSession.default
            guard session.activationState == .activated, session.isReachable else { return }
            session.sendMessage([LiveLink.samplesKey: data], replyHandler: nil, errorHandler: nil)
        }
    }
}
