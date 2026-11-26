import AVFoundation
import SwiftUI

/// What the iPhone is playing through: Bluetooth headphones connected, and whether any app is playing audio.
/// Readable from the background without taking over the audio session.
enum AudioRoute {
    /// An app that never set a category reads other apps' playback unreliably. Ambient + mix-with-others is the
    /// quietest category there is: setting it (without activating the session) never pauses or ducks anything.
    private static let prepared: Void = {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }()

    static func current() -> [String: Any] {
        _ = prepared
        let session = AVAudioSession.sharedInstance()
        let bt = session.currentRoute.outputs.first { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType) }
        // two signals: any other audio at all, and "another app is playing audio that does not mix" (Spotify, Music,
        // podcasts); either one means something is playing
        let other = session.isOtherAudioPlaying, exclusive = session.secondaryAudioShouldBeSilencedHint
        return ["bluetooth": bt != nil, "device": bt?.portName ?? "", "playing": other || exclusive,
                "other": other, "exclusive": exclusive]
    }
}

/// Faces tab: what the watch is told about playback, live, so it can be checked while music plays.
struct AudioCard: View {
    @State private var info: [String: Any] = [:]
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Card {
            Eyebrow(text: "Music on the watch")
            Text((info["playing"] as? Bool ?? false) ? "Playing" : "Nothing playing")
                .font(Theme.serif(20)).foregroundStyle(Theme.ivory)
            Text("other audio: \(flag("other")) · non-mixing app: \(flag("exclusive")) · headphones: \(headphones)")
                .font(.caption).foregroundStyle(Theme.muted)
        }
        .onAppear { info = AudioRoute.current() }
        .onReceive(tick) { _ in info = AudioRoute.current() }
    }

    private func flag(_ key: String) -> String { (info[key] as? Bool ?? false) ? "yes" : "no" }
    private var headphones: String {
        (info["bluetooth"] as? Bool ?? false) ? (info["device"] as? String ?? "yes") : "no"
    }
}
