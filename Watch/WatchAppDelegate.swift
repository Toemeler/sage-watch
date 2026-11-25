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

    /// the iPhone app opened Sage: to start recording (Data tab, "Start on watch") or to keep it awake for live breathing
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        if WatchLaunch.isLive(workoutConfiguration) {
            LiveStreamer.shared.keepAwake(true)
            return
        }
        Recorder.shared.keepRunning = true
        Recorder.shared.start()
    }
}
