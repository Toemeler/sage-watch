import Foundation
import WatchConnectivity

/// Streams the wrist's motion (10 times a second, averaged from the recorder's samples) to the iPhone while its
/// live breathing screen is open. The iPhone repeats its request every few seconds; without one for 20 s the stream
/// stops by itself, so a closed or crashed iPhone app never keeps the watch sending.
final class LiveStreamer {
    static let shared = LiveStreamer()

    private let queue = DispatchQueue(label: "sage.live", qos: .userInitiated)
    private var on = false
    private var lastRequest = Date.distantPast
    private var buffer: [Float] = []

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
