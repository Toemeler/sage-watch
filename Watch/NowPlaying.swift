import SwiftUI
import WatchKit
import WatchConnectivity

/// Headphones and playback on the iPhone, asked from the watch (the watch cannot see the iPhone's audio route).
@MainActor
final class AudioModel: ObservableObject {
    static let shared = AudioModel()

    @Published private(set) var bluetooth = false
    @Published private(set) var device = ""
    @Published private(set) var playing = false
    private var lastCheck = Date.distantPast


    /// at most every 15 s unless forced
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheck) > 15 else { return }
        lastCheck = Date()
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            bluetooth = false; playing = false; return
        }
        session.sendMessage([LampLink.commandKey: LampLink.audio], replyHandler: { reply in
            Task { @MainActor in
                self.bluetooth = reply["bluetooth"] as? Bool ?? false
                self.device = reply["device"] as? String ?? ""
                self.playing = reply["playing"] as? Bool ?? false
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.bluetooth = false; self.playing = false }
        })
    }
}
