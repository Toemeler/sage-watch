import Foundation
import WatchConnectivity

/// One probe run as it arrived from the watch.
struct Segment: Identifiable, Hashable {
    let id: String
    let start: Date?
    let end: Date?
    let files: Int
    let bytes: Int64

    var title: String {
        guard let start else { return id }
        let from = start.formatted(date: .abbreviated, time: .shortened)
        guard let end else { return "\(from) → running" }
        return "\(from) → \(end.formatted(date: .omitted, time: .shortened))"
    }

    var detail: String {
        "\(files) files · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

/// Receives the probe's files from the watch and keeps them in `Documents/Recordings/<segment>/`
/// (also visible in the Files app under "On My iPhone › Sage"), and hands its live snapshots to `ProbeStore`.
final class Receiver: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = Receiver()

    @Published private(set) var segments: [Segment] = []
    @Published private(set) var lastReceived: Date?
    @Published private(set) var filesReceived = 0
    @Published private(set) var watchPaired = false
    @Published private(set) var watchAppInstalled = false

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)
    }

    func activate() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        var list: [Segment] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            var bytes: Int64 = 0
            for n in names {
                let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path)
                bytes += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            }
            let meta = Self.meta(in: dir)
            list.append(Segment(
                id: dir.lastPathComponent,
                start: (meta["start"] as? Double).map { Date(timeIntervalSince1970: $0) },
                end: (meta["end"] as? Double).map { Date(timeIntervalSince1970: $0) },
                files: names.filter { $0.hasSuffix(".csv") }.count,
                bytes: bytes))
        }
        segments = list.sorted { $0.id > $1.id }
    }

    func delete(_ segment: Segment) {
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(segment.id, isDirectory: true))
        reload()
    }

    static func meta(in dir: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(RecordingFormat.metaName)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// a zip of one segment (CSV files and segment.json) to share
    static func zip(_ segment: Segment) throws -> URL {
        let dir = root.appendingPathComponent(segment.id, isDirectory: true)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(segment.id).zip")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordinatorError) { zipped in
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipped, to: dest)
            } catch {
                copyError = error
            }
        }
        if let e = coordinatorError ?? copyError { throw e }
        return dest
    }

    private static func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // the file must be moved before this method returns
        let meta = file.metadata ?? [:]
        let segment = Self.safe(meta["segment"] as? String ?? "unknown")
        var name = Self.safe(meta["name"] as? String ?? file.fileURL.lastPathComponent)
        let dir = Self.root.appendingPathComponent(segment, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if name.hasSuffix(RecordingFormat.compressedSuffix) {
            name = String(name.dropLast(RecordingFormat.compressedSuffix.count))
            if let packed = try? Data(contentsOf: file.fileURL),
               let raw = try? (packed as NSData).decompressed(using: .zlib) as Data {
                try? raw.write(to: dir.appendingPathComponent(name), options: .atomic)
            }
        } else {
            let dest = dir.appendingPathComponent(name)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: file.fileURL, to: dest)
        }
        DispatchQueue.main.async {
            self.lastReceived = Date()
            self.filesReceived += 1
            self.reload()
        }
    }

    /// the probe's live snapshot, once a second
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let snap = message[ProbeLink.snapshotKey] as? [String: Any] else { return }
        let wave = message[ProbeLink.waveKey] as? Data
        DispatchQueue.main.async { ProbeStore.shared.receive(snap, wave: wave) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([:])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        updateWatchState(session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        updateWatchState(session)
    }

    private func updateWatchState(_ session: WCSession) {
        let paired = session.isPaired, installed = session.isWatchAppInstalled
        DispatchQueue.main.async {
            self.watchPaired = paired
            self.watchAppInstalled = installed
        }
    }
}
