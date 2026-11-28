import WatchKit
import HealthKit

/// Launch-time wiring: the iPhone link, workout recovery after a relaunch, and starts requested from the iPhone.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Outbox.shared.activate()
    }

    /// watchOS relaunched the app while its workout session was still running
    func handleActiveWorkoutRecovery() {
        DataProbe.shared.recover()
    }

    /// the iPhone opened the app ("Open on the watch and start")
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        DataProbe.shared.start()
    }
}
