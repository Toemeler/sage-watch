import Foundation
import CoreMotion

/// What you are doing, from Apple's motion coprocessor (still, walking, running, cycling, driving).
///
/// Every change is written to the recording's activity stream and drives the face's "on the move" and
/// "taking a break" modes. Works while Sage runs, which with the recorder on is all the time.
final class ActivityMonitor: ObservableObject {
    static let shared = ActivityMonitor()

    @Published private(set) var context: ActivityContext?
    @Published private(set) var available = CMMotionActivityManager.isActivityAvailable()

    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "sage.activity"
        return q
    }()
    private var running = false
    private var lastLogged: (ActivityKind, Int)?

    private init() {}

    func start() {
        guard available, !running else { return }
        running = true
        manager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let self, let a = activity else { return }
            let kind = Self.kind(of: a)
            let confidence = a.confidence.rawValue
            let at = a.startDate
            DispatchQueue.main.async { self.update(kind, confidence: confidence, at: at) }
        }
    }

    func stop() {
        guard running else { return }
        manager.stopActivityUpdates()
        running = false
    }

    /// the recording just (re)started: write the current state into it, so every segment starts with one
    func logCurrent() {
        guard let c = context else { return }
        Recorder.shared.logActivity(at: Date().timeIntervalSince1970, c.kind, confidence: c.confidence)
        lastLogged = (c.kind, c.confidence)
    }

    private func update(_ kind: ActivityKind, confidence: Int, at: Date) {
        let previous = context
        var lastMovingEnd = previous?.lastMovingEnd
        if let p = previous, p.kind.isMoving, !kind.isMoving { lastMovingEnd = at }
        let since = (previous?.kind == kind) ? (previous?.since ?? at) : at
        context = ActivityContext(kind: kind, confidence: confidence, since: since, lastMovingEnd: lastMovingEnd)
        if lastLogged.map({ $0.0 != kind || $0.1 != confidence }) ?? true {
            Recorder.shared.logActivity(at: at.timeIntervalSince1970, kind, confidence: confidence)
            lastLogged = (kind, confidence)
        }
    }

    /// one label for a CMMotionActivity, which can set several flags at once (stationary in a car)
    static func kind(of a: CMMotionActivity) -> ActivityKind {
        if a.automotive { return .automotive }
        if a.cycling { return .cycling }
        if a.running { return .running }
        if a.walking { return .walking }
        if a.stationary { return .stationary }
        return .unknown
    }
}
