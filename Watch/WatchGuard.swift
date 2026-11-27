import Foundation
import WatchKit

/// A quiet watchman for what the night depends on, checked once a minute while the app runs (the recorder keeps it
/// running through the night):
/// - **Battery guard (F18):** at your usual bedtime, a watch below 30 % that is not charging may not last until the
///   smart wake. One tap and a note, once per night.
/// The decision is FaceRules.batteryGuard (tested).
@MainActor
final class WatchGuard: ObservableObject {
    static let shared = WatchGuard()

    @Published private(set) var batteryWarnedAt: Date?

    private var loop: Task<Void, Never>?
    private var warnedBedtime: Date?            // the bedtime already warned for (once per night)

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
}
