import XCTest
@testable import Sage

/// Automatic lamp steps never undo what you set: a sunrise never dims, a wind-down never brightens or switches on.
final class LampRulesTests: XCTestCase {
    private func state(on: Bool, dim: Int, temp: Int? = 2700) -> LampLink.State {
        var s = LampLink.State(); s.on = on; s.dimming = dim; s.temp = temp; s.home = true
        if temp == nil { s.rgb = (255, 0, 0) }
        return s
    }

    func testSunriseStartsLowAndEndsBright() {
        let first = LampRules.sunrise(t: 0, current: state(on: false, dim: 50))
        XCTAssertEqual(first?["dimming"] as? Int, 10)
        XCTAssertEqual(first?["temp"] as? Int, 2200)
        let last = LampRules.sunrise(t: 1, current: state(on: true, dim: 40))
        XCTAssertEqual(last?["dimming"] as? Int, 80)
        XCTAssertEqual(last?["temp"] as? Int, 4200)
    }

    func testSunriseNeverDimsABrighterLamp() {
        // up early, lamp on at 90 %: the window opens, the sunrise must leave it alone
        XCTAssertNil(LampRules.sunrise(t: 0, current: state(on: true, dim: 90)))
        XCTAssertNil(LampRules.sunrise(t: 0.5, current: state(on: true, dim: 60)))      // 0.5 → 28 %
    }

    func testWindDownOnlyLowers() {
        let start = state(on: true, dim: 80, temp: 4000)
        let step = LampRules.windDown(t: 0.5, start: start, current: start)
        XCTAssertEqual(step?["dimming"] as? Int, 45)
        XCTAssertEqual(step?["temp"] as? Int, 3100)
        // you dimmed it to 20 % meanwhile: the next step must not raise it back
        // (the step would be 38 % / 2920 K; both are above what you set, so nothing is sent)
        XCTAssertNil(LampRules.windDown(t: 0.6, start: start, current: state(on: true, dim: 20, temp: 2700)))
    }

    func testWindDownNeverSwitchesOnAndLeavesColour() {
        XCTAssertNil(LampRules.windDown(t: 0.5, start: state(on: true, dim: 80), current: state(on: false, dim: 80)))
        let colour = LampRules.windDown(t: 0.5, start: state(on: true, dim: 80, temp: nil), current: state(on: true, dim: 80, temp: nil))
        XCTAssertNil(colour?["temp"])
        XCTAssertEqual(colour?["dimming"] as? Int, 45)
    }
}
