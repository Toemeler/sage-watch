import AVFoundation

/// What the iPhone is playing through: Bluetooth headphones connected, and whether any app is playing audio.
/// Readable from the background without taking over the audio session.
enum AudioRoute {
    static func current() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let bt = session.currentRoute.outputs.first { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType) }
        return ["bluetooth": bt != nil, "device": bt?.portName ?? "", "playing": session.isOtherAudioPlaying]
    }
}
