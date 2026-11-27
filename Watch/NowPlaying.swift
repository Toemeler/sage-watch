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
    private var answered = false        // the iPhone has answered at least once since the last failure
    private var answeredAt: Date?       // the last real answer (the bars ride out a brief drop after it)
    private var polling: Task<Void, Never>?

    /// Checks every 10 s while Sage is in front, every 3 s until the iPhone has answered (right after launch the
    /// watch link is often still starting). Reads the app state live each time: a value captured when the loop was
    /// created would stay "inactive" forever if Sage launched in the background, which is how the bars got stuck.
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { @MainActor in
            while !Task.isCancelled {
                if WKApplication.shared().applicationState == .active { refresh(force: !answered) }
                try? await Task.sleep(for: .seconds(answered ? 10 : 3))
            }
        }
    }

    /// at most every 8 s unless forced
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheck) > 8 else { return }
        lastCheck = Date()
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else {
            status = "Watch link starting…"; return
        }
        guard session.isReachable else {
            playing = FaceRules.keepMusicBars(lastPlaying: playing, sinceAnswer: answeredAt.map { Date().timeIntervalSince($0) })
            bluetooth = false; status = "iPhone not reachable"; answered = false; return
        }
        session.sendMessage([LampLink.commandKey: LampLink.audio], replyHandler: { reply in
            Task { @MainActor in
                self.bluetooth = reply["bluetooth"] as? Bool ?? false
                self.device = reply["device"] as? String ?? ""
                self.playing = reply["playing"] as? Bool ?? false
                self.status = reply["playing"] == nil ? "iPhone app too old" : (self.playing ? "Playing" : "Nothing playing")
                self.answered = true
                self.answeredAt = Date()
            }
        }, errorHandler: { error in
            Task { @MainActor in
                self.bluetooth = false; self.answered = false
                self.playing = FaceRules.keepMusicBars(lastPlaying: self.playing,
                                                       sinceAnswer: self.answeredAt.map { Date().timeIntervalSince($0) })
                self.status = "iPhone did not answer (\((error as NSError).code))"
            }
        })
    }
}
