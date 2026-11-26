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
    @Published private(set) var cover: Image?
    @Published private(set) var track: String?
    private var artURL: String?
    private var lastCheck = Date.distantPast

    /// the cover is shown while Spotify reports playing
    var showsCover: Bool { cover != nil && spotifyPlaying }
    @Published private(set) var spotifyPlaying = false

    /// at most every 15 s unless forced
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheck) > 15 else { return }
        lastCheck = Date()
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            bluetooth = false; playing = false; return
        }
        var message: [String: Any] = [LampLink.commandKey: LampLink.audio]
        if let artURL { message["artURL"] = artURL }
        session.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in
                self.bluetooth = reply["bluetooth"] as? Bool ?? false
                self.device = reply["device"] as? String ?? ""
                self.spotifyPlaying = reply["spotifyPlaying"] as? Bool ?? false
                self.playing = (reply["playing"] as? Bool ?? false) || self.spotifyPlaying
                let title = reply["title"] as? String ?? "", artist = reply["artist"] as? String ?? ""
                self.track = title.isEmpty ? nil : (artist.isEmpty ? title : "\(title) · \(artist)")
                let url = reply["artURL"] as? String
                if let data = reply["art"] as? Data, let img = UIImage(data: data) {
                    self.cover = Image(uiImage: img); self.artURL = url
                } else if url == nil || url?.isEmpty == true {
                    self.cover = nil; self.artURL = nil
                }
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.bluetooth = false; self.playing = false }
        })
    }
}

/// Music button on the face while something plays; opens the system Now Playing controls
/// (play/pause, skip, back, crown for volume) for whatever app plays on the iPhone, Spotify included.
struct MusicButton: View {
    @ObservedObject var audio: AudioModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "playpause.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FaceGeometry.Palette.ivory)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(hex: 0x0D0E0C)))
                .overlay(Circle().stroke(FaceGeometry.Palette.rim, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Now playing"))
    }
}

/// Small badge at the top of the face while Bluetooth headphones are connected to the iPhone.
struct BluetoothBadge: View {
    var body: some View {
        Image(systemName: "headphones")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(hex: 0x5AA0E6))
            .padding(4)
            .background(Circle().fill(Color(hex: 0x0D0E0C)))
            .accessibilityLabel(Text("Headphones connected"))
    }
}
