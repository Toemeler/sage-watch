import Foundation
import WatchKit

/// Two quiet watchmen for the things the night depends on, checked once a minute while the app runs (the recorder
/// keeps it running through the night):
/// - **Battery guard (F18):** at your usual bedtime, a watch below 30 % that is not charging may not last until the
///   smart wake. One tap and a note, once per night.
/// - **Recording stopped (F19):** Record is on, but no motion has been written for 10 min. One tap and a note with
///   Restart, once per stall; during a sleep block it waits until the block ends.
/// The decisions are FaceRules.batteryGuard and FaceRules.recordingStalled (tested).
@MainActor
final class WatchGuard: ObservableObject {
    static let shared = WatchGuard()

    @Published private(set) var batteryWarnedAt: Date?
    @Published private(set) var stalledAt: Date?

    private var loop: Task<Void, Never>?
    private var lastCount = -1
    private var lastChange = Date()
    /// the bedtime already warned for (once per night, kept across a relaunch inside the 5-min window)
    private var warnedBedtime: Date? {
        get { UserDefaults.standard.object(forKey: "guardBatteryBedtime") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "guardBatteryBedtime") }
    }
    private var stallWarned = false              // until samples move again

    /// start the minute checks (idempotent)
    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor in
            while !Task.isCancelled {
                check(now: Date())
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func check(now: Date) {
        let rec = Recorder.shared
        // F19: motion samples are counted every 10 s while recording; no change for 10 min is a stall
        if rec.motionSamples != lastCount { lastCount = rec.motionSamples; lastChange = now; stallWarned = false }
        if !stallWarned, FaceRules.recordingStalled(keepRunning: rec.keepRunning,
                                                    sinceStart: rec.startedAt.map { now.timeIntervalSince($0) },
                                                    sinceLastSample: now.timeIntervalSince(lastChange),
                                                    sleeping: FaceMode.auto(now) == .sleeping) {
            stallWarned = true
            WKInterfaceDevice.current().play(.click)
            stalledAt = now
        }

        // F18: within 5 min after the usual night bedtime
        var bed = LampAutomation.shared.nextBedtime(after: now.addingTimeInterval(-5 * 60))
        while bed.nap { bed = LampAutomation.shared.nextBedtime(after: bed.at.addingTimeInterval(60)) }
        guard bed.at <= now, warnedBedtime != bed.at else { return }
        let power = BatteryReader.read(now)
        if FaceRules.batteryGuard(percent: power.percent, charging: power.charging, recording: rec.keepRunning) {
            warnedBedtime = bed.at
            WKInterfaceDevice.current().play(.click)
            batteryWarnedAt = now
        }
    }

    /// the restart was asked for: give it time to start before a stall can be reported again
    func restarted() {
        lastChange = Date()
        stallWarned = false
    }
}
