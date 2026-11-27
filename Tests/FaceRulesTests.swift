import XCTest
@testable import Sage

final class FaceRulesTests: XCTestCase {
    func testCrownUpOpensTheLampDownNeedsALongTurn() {
        XCTAssertEqual(FaceRules.crownAction(delta: 3, sleeping: false), .none)
        XCTAssertEqual(FaceRules.crownAction(delta: 4, sleeping: false), .openLamp)
        XCTAssertEqual(FaceRules.crownAction(delta: -4, sleeping: false), .none)       // a brush down does nothing
        XCTAssertEqual(FaceRules.crownAction(delta: -11, sleeping: false), .none)
        XCTAssertEqual(FaceRules.crownAction(delta: -12, sleeping: false), .startNap)
    }

    func testNapLengthStepsAndStopsAtTheEnds() {
        XCTAssertEqual(FaceRules.napLength(100, steps: 1), 105)
        XCTAssertEqual(FaceRules.napLength(100, steps: -2), 90)
        XCTAssertEqual(FaceRules.napLength(25, steps: -3), 20)
        XCTAssertEqual(FaceRules.napLength(125, steps: 4), 130)
    }

    func testBatteryGuardOnlyWhenTheNightIsAtRisk() {
        XCTAssertTrue(FaceRules.batteryGuard(percent: 22, charging: false, recording: true))
        XCTAssertFalse(FaceRules.batteryGuard(percent: 22, charging: true, recording: true))    // on the charger
        XCTAssertFalse(FaceRules.batteryGuard(percent: 22, charging: false, recording: false))  // no smart wake to protect
        XCTAssertFalse(FaceRules.batteryGuard(percent: 30, charging: false, recording: true))
        XCTAssertFalse(FaceRules.batteryGuard(percent: nil, charging: false, recording: true))  // unknown: quiet
    }

    func testRecordingStallNeedsTenQuietMinutes() {
        XCTAssertTrue(FaceRules.recordingStalled(keepRunning: true, sinceStart: 3600, sinceLastSample: 601))
        XCTAssertFalse(FaceRules.recordingStalled(keepRunning: true, sinceStart: 3600, sinceLastSample: 120))
        XCTAssertFalse(FaceRules.recordingStalled(keepRunning: false, sinceStart: nil, sinceLastSample: 9999))  // Record off
        XCTAssertFalse(FaceRules.recordingStalled(keepRunning: true, sinceStart: 60, sinceLastSample: 9999))    // just started
        XCTAssertTrue(FaceRules.recordingStalled(keepRunning: true, sinceStart: nil, sinceLastSample: 700))     // stopped by itself
        XCTAssertFalse(FaceRules.recordingStalled(keepRunning: true, sinceStart: 3600, sinceLastSample: 9999, sleeping: true))  // not at night
    }

    func testCrownDoesNothingWhileAsleep() {
        XCTAssertEqual(FaceRules.crownAction(delta: 20, sleeping: true), .none)
        XCTAssertEqual(FaceRules.crownAction(delta: -20, sleeping: true), .none)
    }

    func testDoubleTapTogglesOnlyWhenItIsSafe() {
        XCTAssertEqual(FaceRules.doubleTap(sleeping: false, dimmed: false, bedside: false, home: true), .toggleLamp)
        XCTAssertEqual(FaceRules.doubleTap(sleeping: false, dimmed: false, bedside: false, home: false), .openLamp)
        XCTAssertEqual(FaceRules.doubleTap(sleeping: true, dimmed: false, bedside: false, home: true), .none)
        XCTAssertEqual(FaceRules.doubleTap(sleeping: false, dimmed: true, bedside: false, home: true), .none)
        XCTAssertEqual(FaceRules.doubleTap(sleeping: false, dimmed: false, bedside: true, home: true), .none)
    }

    func testDoubleTapStopsARingingAlarmFirst() {
        // ringing in the morning window: still a "sleep block" for the face, but double tap must stop the alarm
        XCTAssertEqual(FaceRules.doubleTap(ringing: true, sleeping: true, dimmed: true, bedside: false, home: true), .stopAlarm)
    }

    func testBedsideCrownIsANightLightSwitch() {
        XCTAssertEqual(FaceRules.bedsideCrown(delta: 4), .nightLight)
        XCTAssertEqual(FaceRules.bedsideCrown(delta: -4), .lampOff)
        XCTAssertEqual(FaceRules.bedsideCrown(delta: 2), .none)
        // the night light is never bright
        XCTAssertEqual(FaceRules.nightLight["dimming"] as? Int, 10)
        XCTAssertNil(FaceRules.nightLight["temp"])
    }

    func testBedsideOnlyOnTheChargerAtNight() {
        XCTAssertTrue(FaceRules.bedside(hour: 23, charging: true))
        XCTAssertTrue(FaceRules.bedside(hour: 3, charging: true))
        XCTAssertFalse(FaceRules.bedside(hour: 7, charging: true))
        XCTAssertFalse(FaceRules.bedside(hour: 20, charging: true))
        XCTAssertFalse(FaceRules.bedside(hour: 23, charging: false))
    }
}
