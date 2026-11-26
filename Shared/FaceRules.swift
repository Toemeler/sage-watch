import Foundation

/// Decisions the watch face makes, kept apart from the views so they can be tested.
enum FaceRules {
    enum CrownAction: Equatable { case none, openLamp, startNap }

    /// detents up that open the lamp, detents down that start a nap
    static let lampDetents = 4.0
    static let napDetents = 12.0
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

    /// the bedside clock: on the charger between 21:00 and 07:00
    static func bedside(hour: Int, charging: Bool) -> Bool {
        charging && (hour >= 21 || hour < 7)
    }
}
