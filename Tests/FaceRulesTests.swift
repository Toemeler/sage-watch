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
