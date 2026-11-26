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
    /// the last answer in plain words, for the long-press menu ("Playing", "iPhone not reachable", ...)
    @Published private(set) var status = "Not checked yet"
    private var lastCheck = Date.distantPast

    /// at most every 8 s unless forced
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheck) > 8 else { return }
        lastCheck = Date()
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else {
            status = "Watch link starting…"; return
        }
        guard session.isReachable else {
            playing = false; bluetooth = false; status = "iPhone not reachable"; return
        }
        session.sendMessage([LampLink.commandKey: LampLink.audio], replyHandler: { reply in
            Task { @MainActor in
                self.bluetooth = reply["bluetooth"] as? Bool ?? false
                self.device = reply["device"] as? String ?? ""
                self.playing = reply["playing"] as? Bool ?? false
                self.status = reply["playing"] == nil ? "iPhone app too old" : (self.playing ? "Playing" : "Nothing playing")
            }
        }, errorHandler: { error in
            Task { @MainActor in
                self.bluetooth = false; self.playing = false
                self.status = "iPhone did not answer (\((error as NSError).code))"
            }
        })
    }
}
