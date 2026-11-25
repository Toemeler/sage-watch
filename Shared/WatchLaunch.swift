import HealthKit

/// The iPhone opens Sage on the watch through HealthKit's "start watch app", which hands the watch a workout
/// configuration. Its location type says why: indoor = start recording, unknown = keep Sage awake for live breathing.
enum WatchLaunch {
    static func configuration(live: Bool) -> HKWorkoutConfiguration {
        let c = HKWorkoutConfiguration()
        c.activityType = .mindAndBody
        c.locationType = live ? .unknown : .indoor
        return c
    }

    static func isLive(_ c: HKWorkoutConfiguration) -> Bool { c.locationType == .unknown }
}
