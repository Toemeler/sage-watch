import Foundation
import WatchConnectivity

/// Sends finished recording files to the iPhone through WatchConnectivity.
///
/// A file stays in `Documents/Outbox/<segment>/` until the iPhone confirms it, so nothing is lost when the phone is
/// out of reach; anything left over is sent again when the session activates or when you tap "Send now".
final class Outbox: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = Outbox()

    @Published private(set) var pending = 0
    @Published private(set) var sent = 0

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Outbox", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "sage.outbox", qos: .utility)

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        refreshPending()
    }

    /// Moves a finished file into the outbox (zlib-compressed when `compress`) and queues it for the iPhone.
    func ship(_ url: URL, segment: String, compress: Bool) {
        queue.async {
            let fm = FileManager.default
            let dir = Self.root.appendingPathComponent(segment, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent(url.lastPathComponent)
            do {
                if compress {
                    let data = try Data(contentsOf: url)
                    let packed = try (data as NSData).compressed(using: .zlib) as Data
                    dest = dir.appendingPathComponent(url.lastPathComponent + RecordingFormat.compressedSuffix)
                    try packed.write(to: dest, options: .atomic)
                    try? fm.removeItem(at: url)
                } else {
                    try? fm.removeItem(at: dest)
                    try fm.moveItem(at: url, to: dest)
                }
            } catch {
                return      // the file stays where it was and is picked up again by `shipLeftovers`
            }
            self.send(dest, segment: segment)
        }
    }

    /// Writes a small file (the segment description) straight into the outbox and queues it.
    func shipData(_ data: Data, name: String, segment: String) {
        queue.async {
            let dir = Self.root.appendingPathComponent(segment, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(name)
            guard (try? data.write(to: dest, options: .atomic)) != nil else { return }
            self.send(dest, segment: segment)
        }
    }

    /// Ships every file left in `live` (a recording that ended without closing its files), except the running segment.
    func shipLeftovers(in live: URL, except running: String?) {
        queue.async {
            let fm = FileManager.default
            guard let segments = try? fm.contentsOfDirectory(at: live, includingPropertiesForKeys: nil) else { return }
            for seg in segments where seg.lastPathComponent != running {
                for f in (try? fm.contentsOfDirectory(at: seg, includingPropertiesForKeys: nil)) ?? [] {
                    self.ship(f, segment: seg.lastPathComponent, compress: f.pathExtension == "csv")
                }
                if ((try? fm.contentsOfDirectory(atPath: seg.path)) ?? []).isEmpty { try? fm.removeItem(at: seg) }
            }
        }
    }

    /// Queues everything in the outbox that is not already on its way.
    func resendAll() {
        queue.async {
            let fm = FileManager.default
            guard let segments = try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil) else { return }
            for seg in segments {
                for f in (try? fm.contentsOfDirectory(at: seg, includingPropertiesForKeys: nil)) ?? [] {
                    self.send(f, segment: seg.lastPathComponent)
                }
            }
        }
        refreshPending()
    }

    private func send(_ url: URL, segment: String) {
        DispatchQueue.main.async {
            let session = WCSession.default
            guard WCSession.isSupported(), session.activationState == .activated else { self.refreshPending(); return }
            let path = url.standardizedFileURL.path
            if session.outstandingFileTransfers.contains(where: { $0.file.fileURL.standardizedFileURL.path == path }) { return }
            session.transferFile(url, metadata: ["segment": segment, "name": url.lastPathComponent])
            self.refreshPending()
        }
    }

    private func refreshPending() {
        queue.async {
            let fm = FileManager.default
            var count = 0
            for seg in (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [] {
                count += ((try? fm.contentsOfDirectory(atPath: seg.path)) ?? []).count
            }
            DispatchQueue.main.async { self.pending = count }
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { resendAll() }
    }

    // the iPhone's live breathing screen asks for the motion stream (and repeats the request while it is open)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(handleLive(message))
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        _ = handleLive(message)
    }

    private func handleLive(_ message: [String: Any]) -> [String: Any] {
        guard message[LiveLink.commandKey] as? String == LiveLink.breathing else { return [:] }
        LiveStreamer.shared.request(on: message[LiveLink.onKey] as? Bool ?? false)
        return [LiveLink.recordingKey: Recorder.shared.isRunning]
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        guard error == nil else { refreshPending(); return }
        queue.async {
            let fm = FileManager.default
            try? fm.removeItem(at: url)
            let dir = url.deletingLastPathComponent()
            if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty { try? fm.removeItem(at: dir) }
            DispatchQueue.main.async { self.sent += 1 }
            self.refreshPending()
        }
    }
}
