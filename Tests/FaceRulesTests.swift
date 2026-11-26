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

    func testBedsideOnlyOnTheChargerAtNight() {
        XCTAssertTrue(FaceRules.bedside(hour: 23, charging: true))
        XCTAssertTrue(FaceRules.bedside(hour: 3, charging: true))
        XCTAssertFalse(FaceRules.bedside(hour: 7, charging: true))
        XCTAssertFalse(FaceRules.bedside(hour: 20, charging: true))
        XCTAssertFalse(FaceRules.bedside(hour: 23, charging: false))
    }
}
