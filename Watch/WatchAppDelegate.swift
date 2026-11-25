import WatchKit
import HealthKit

/// Launch-time wiring: the iPhone link, workout recovery after a relaunch, and starts requested from the iPhone.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Outbox.shared.activate()
    }

    /// watchOS relaunched Sage while its workout session was still running
    func handleActiveWorkoutRecovery() {
        Recorder.shared.recover()
    }

    /// the iPhone app asked the watch to start recording (Data tab, "Start on watch")
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Recorder.shared.keepRunning = true
        Recorder.shared.start()
    }
}
