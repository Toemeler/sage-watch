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
