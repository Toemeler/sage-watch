import Foundation

/// Decisions the watch face makes, kept apart from the views so they can be tested.
enum FaceRules {
    enum CrownAction: Equatable { case none, openLamp, startNap }

    /// detents up that open the lamp, detents down that start a nap
    static let lampDetents = 4.0
    static let napDetents = 12.0
    /// F17: crown detents per 5-minute step of the nap's length
    static let napStepDetents = 4.0

    /// F17: the nap's length after `steps` crown steps from `minutes` (5 min each, 20...130)
    static func napLength(_ minutes: Double, steps: Int) -> Double {
        min(AlarmSettings.napLengthRange.upperBound, max(AlarmSettings.napLengthRange.lowerBound, minutes + Double(steps) * AlarmSettings.napLengthStep))
    }

    /// F18: at bedtime, warn below this battery when not charging (the recorder and the smart wake need the night)
    static let batteryGuardPercent = 30

    /// F18: warn at bedtime? Only while Record is on (without it there is no smart wake to protect), not on the
    /// charger, and below 30 %. An unknown level never warns.
    static func batteryGuard(percent: Int?, charging: Bool, recording: Bool) -> Bool {
        guard recording, !charging, let p = percent else { return false }
        return p < batteryGuardPercent
    }

    /// F19: no motion written for this long while Record is on is a stall
    static let stallSeconds: TimeInterval = 10 * 60

    /// F19: is the recording stalled? Record is on, the run (if any) began more than 2 min ago (a normal start or
    /// restart is not a stall), and nothing has been written for 10 min. `sinceStart` nil: not running although
    /// Record is on, which counts once the 10 min have passed too.
    static func recordingStalled(keepRunning: Bool, sinceStart: TimeInterval?, sinceLastSample: TimeInterval) -> Bool {
        guard keepRunning else { return false }
        if let s = sinceStart, s < 120 { return false }
        return sinceLastSample >= stallSeconds
    }

    /// a pause longer than this starts a new crown gesture
    static let gesturePause: TimeInterval = 1.5

    /// what a crown movement of `delta` detents since the gesture began means. Up opens the lamp quickly; down needs
    /// a long, deliberate turn, so a nap is never started by a brush. Nothing during a sleep block.
    static func crownAction(delta: Double, sleeping: Bool) -> CrownAction {
        if sleeping { return .none }
        if delta <= -napDetents { return .startNap }
        if delta >= lampDetents { return .openLamp }
        return .none
    }

    enum DoubleTapAction: Equatable { case none, stopAlarm, toggleLamp, openLamp }

    /// double tap (pinch twice) on the face: toggles the lamp when the watch knows it is at home, otherwise opens
    /// the lamp panel (which says why) rather than switching on from a stale state; nothing during a sleep block,
    /// in always-on or on the bedside clock
    /// While the alarm rings (or a test alarm taps), double tap stops it, as on Apple's own alarms; that takes
    /// precedence over everything else.
    static func doubleTap(ringing: Bool = false, sleeping: Bool, dimmed: Bool, bedside: Bool, home: Bool) -> DoubleTapAction {
        if ringing { return .stopAlarm }
        if sleeping || dimmed || bedside { return .none }
        return home ? .toggleLamp : .openLamp
    }

    enum BedsideCrown: Equatable { case none, nightLight, lampOff }

    /// F12: on the bedside clock the crown is a night-light switch: a turn up sets the lamp to a dim red night
    /// light, a turn down switches the lamp off. Never anything bright (see nightLight).
    static func bedsideCrown(delta: Double) -> BedsideCrown {
        if delta >= lampDetents { return .nightLight }
        if delta <= -lampDetents { return .lampOff }
        return .none
    }

    /// the night light: deep red at the bulb's minimum (WiZ cannot go below 10 %), so getting up does not wake you
    static let nightLight: [String: Any] = ["state": true, "r": 255, "g": 28, "b": 0, "dimming": 10]

    /// the bedside clock: on the charger between 21:00 and 07:00
    static func bedside(hour: Int, charging: Bool) -> Bool {
        charging && (hour >= 21 || hour < 7)
    }
}
