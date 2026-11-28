import HealthKit

/// The iPhone opens the app on the watch through HealthKit's "start watch app", which hands the watch a workout
/// configuration; the watch then starts the probe (its workout session keeps it running in the background).
enum WatchLaunch {
    static func configuration() -> HKWorkoutConfiguration {
        let c = HKWorkoutConfiguration()
        c.activityType = .mindAndBody
        c.locationType = .indoor
        return c
    }
}
