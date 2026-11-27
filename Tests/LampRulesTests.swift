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

    func testRestorePutsTheLampBackExactly() {
        var off = LampLink.State(); off.on = false
        XCTAssertEqual(LampRules.restore(off)["state"] as? Bool, false)
        XCTAssertNil(LampRules.restore(off)["dimming"])
        var white = LampLink.State(); white.on = true; white.dimming = 35; white.temp = 3000
        XCTAssertEqual(LampRules.restore(white)["temp"] as? Int, 3000)
        XCTAssertEqual(LampRules.restore(white)["dimming"] as? Int, 35)
        var colour = LampLink.State(); colour.on = true; colour.dimming = 60; colour.rgb = (10, 20, 255); colour.temp = nil
        XCTAssertEqual(LampRules.restore(colour)["b"] as? Int, 255)
        XCTAssertNil(LampRules.restore(colour)["temp"])
    }

    func testNightLightTimesOutUnlessYouChangedIt() {
        var red = LampLink.State(); red.on = true; red.dimming = 10; red.rgb = (255, 28, 0); red.temp = nil
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(LampRules.nightLightExpired(current: red, setAt: t0, now: t0.addingTimeInterval(600)))
        XCTAssertTrue(LampRules.nightLightExpired(current: red, setAt: t0, now: t0.addingTimeInterval(900)))
        var brighter = red; brighter.dimming = 40                        // you turned it up: yours, stays
        XCTAssertFalse(LampRules.nightLightExpired(current: brighter, setAt: t0, now: t0.addingTimeInterval(3600)))
        var white = red; white.rgb = nil; white.temp = 2700               // you picked a white: stays
        XCTAssertFalse(LampRules.nightLightExpired(current: white, setAt: t0, now: t0.addingTimeInterval(3600)))
    }

    func testBedtimeTapOnlyWhenNothingElseHandlesIt() {
        XCTAssertTrue(LampRules.bedtimeTap(lampOn: true, dimming: 80, windDownOn: false))
        XCTAssertFalse(LampRules.bedtimeTap(lampOn: true, dimming: 80, windDownOn: true))   // wind-down handles it
        XCTAssertFalse(LampRules.bedtimeTap(lampOn: true, dimming: 25, windDownOn: false))  // already dim
        XCTAssertFalse(LampRules.bedtimeTap(lampOn: false, dimming: 80, windDownOn: false))
    }

    func testPanelKeepsItsControlsThroughAShortDrop() {
        XCTAssertTrue(LampRules.showControls(home: true, sinceConfirmed: nil))
        XCTAssertTrue(LampRules.showControls(home: false, sinceConfirmed: 30))      // one failed check: keep them
        XCTAssertFalse(LampRules.showControls(home: false, sinceConfirmed: 300))    // gone for 5 min: say why
        XCTAssertFalse(LampRules.showControls(home: false, sinceConfirmed: nil))    // never reached
    }

    func testPanelClosesWhenIdleButNeverUnderAFinger() {
        XCTAssertTrue(LampRules.idleClose(idle: 31, touching: false, colours: false))
        XCTAssertFalse(LampRules.idleClose(idle: 10, touching: false, colours: false))
        XCTAssertFalse(LampRules.idleClose(idle: 300, touching: true, colours: false))    // finger on it
        XCTAssertFalse(LampRules.idleClose(idle: 300, touching: false, colours: true))    // choosing a colour
    }

    func testPanelClosesWithTheWristButNotUnderAFinger() {
        XCTAssertTrue(LampRules.closeOnWristDown(active: false, touching: false))
        XCTAssertFalse(LampRules.closeOnWristDown(active: false, touching: true))
        XCTAssertFalse(LampRules.closeOnWristDown(active: true, touching: false))
    }

    func testReconnectRetriesWithoutPilingUp() {
        XCTAssertTrue(LampRules.retryReconnect(sinceLastTry: 8, busy: false))
        XCTAssertFalse(LampRules.retryReconnect(sinceLastTry: 3, busy: false))
        XCTAssertFalse(LampRules.retryReconnect(sinceLastTry: 60, busy: true))           // one still out
    }

    func testArrivalLightOnlyWhenNothingSpeaksAgainstIt() {
        func a(away: TimeInterval = 3600, since: TimeInterval = 120, dark: Bool = true, sleeping: Bool = false, on: Bool = false, panel: Bool = false,
               off: TimeInterval? = nil, windDown: Bool = false) -> [String: Any]? {
            LampRules.arrivalLight(awaySpan: away, sinceAway: since, dark: dark, sleeping: sleeping, lampOn: on, panelOpen: panel,
                                   sinceUserOff: off, inWindDown: windDown)
        }
        XCTAssertEqual(a()?["dimming"] as? Int, 60)
        XCTAssertEqual(a()?["temp"] as? Int, 2700)
        XCTAssertEqual(a(windDown: true)?["dimming"] as? Int, 25)     // inside the wind-down: dim and warm
        XCTAssertNil(a(away: 0))                                      // one flaky answer at home is not leaving
        XCTAssertNil(a(away: 600))                                    // a short drop is not coming home
        XCTAssertNil(a(since: 3 * 3600))                              // home for hours, the watch just had not asked
        XCTAssertNil(a(dark: false))
        XCTAssertNil(a(sleeping: true))
        XCTAssertNil(a(on: true))                                     // never changes a lamp that is on
        XCTAssertNil(a(panel: true))                                  // you are setting it yourself
        XCTAssertNil(a(off: 120))                                     // you just switched it off
        XCTAssertNotNil(a(off: 3600))
        // F23: your evening light when remembered; inside the wind-down still dim and warm
        let mine: [String: Any] = ["dimming": 45, "r": 255, "g": 140, "b": 0]
        let e = LampRules.arrivalLight(awaySpan: 3600, sinceAway: 60, dark: true, sleeping: false, lampOn: false,
                                       panelOpen: false, sinceUserOff: nil, inWindDown: false, evening: mine)
        XCTAssertEqual(e?["dimming"] as? Int, 45)
        XCTAssertEqual(e?["g"] as? Int, 140)
        let late = LampRules.arrivalLight(awaySpan: 3600, sinceAway: 60, dark: true, sleeping: false, lampOn: false,
                                          panelOpen: false, sinceUserOff: nil, inWindDown: true, evening: mine)
        XCTAssertEqual(late?["dimming"] as? Int, 25)
    }

    func testSunTimesForZurich() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Zurich")!
        func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let nov = Sun.times(on: local(2026, 11, 27, 12, 0), lat: 47.37, lon: 8.54, calendar: cal)!
        XCTAssertEqual(nov.rise.timeIntervalSince(local(2026, 11, 27, 7, 46)), 0, accuracy: 5 * 60)
        XCTAssertEqual(nov.set.timeIntervalSince(local(2026, 11, 27, 16, 40)), 0, accuracy: 5 * 60)
        let jun = Sun.times(on: local(2026, 6, 21, 12, 0), lat: 47.37, lon: 8.54, calendar: cal)!
        XCTAssertEqual(jun.set.timeIntervalSince(local(2026, 6, 21, 21, 25)), 0, accuracy: 5 * 60)
        XCTAssertTrue(Sun.dark(at: local(2026, 11, 27, 17, 30), lat: 47.37, lon: 8.54, calendar: cal))
        XCTAssertFalse(Sun.dark(at: local(2026, 6, 21, 20, 30), lat: 47.37, lon: 8.54, calendar: cal))
        XCTAssertNil(Sun.times(on: local(2026, 6, 21, 12, 0), lat: 78, lon: 15, calendar: cal))   // midnight sun
        XCTAssertTrue(Sun.dark(at: local(2026, 6, 21, 22, 0), lat: nil, lon: nil, calendar: cal))  // no position: by the hour
    }

    func testWindDownStartsEarlierOnlyAfterAShortLastNight() {
        func lead(nap: Bool = false, last: Double? = 330, usual: Double? = 450, since: TimeInterval? = 15 * 3600) -> TimeInterval {
            LampRules.windDownLead(base: 3600, nap: nap, lastNightMinutes: last, usualMinutes: usual, sinceLastNight: since)
        }
        XCTAssertEqual(lead(), 5400)                          // 2 h short: 30 min earlier
        XCTAssertEqual(lead(last: 420), 3600)                 // 30 min short: as usual
        XCTAssertEqual(lead(nap: true), 3600)                 // naps keep their lead
        XCTAssertEqual(lead(since: 30 * 3600), 3600)          // that was not last night
        XCTAssertEqual(lead(usual: nil), 3600)                // no usual yet
        XCTAssertEqual(lead(last: nil), 3600)
    }

    func testRecentColoursNewestFirstNoDoubles() {
        XCTAssertEqual(LampRules.recents([], adding: 5), [5])
        XCTAssertEqual(LampRules.recents([5, 9], adding: 12), [12, 5, 9])
        XCTAssertEqual(LampRules.recents([12, 5, 9], adding: 9), [9, 12, 5])      // chosen again: to the front
        XCTAssertEqual(LampRules.recents([12, 5, 9], adding: 30), [30, 12, 5])    // three at most
    }

    func testWheelOpensOnTheCurrentColourAndTheRecentsWhenTheyFit() {
        let half = CGSize(width: 61, height: 81)
        // current and recents close together: the middle of them
        XCTAssertEqual(LampRules.openCentre(current: CGPoint(x: 0, y: 0), recents: [CGPoint(x: 47, y: 0)], half: half),
                       CGPoint(x: 23.5, y: 0))
        // a recent far away: the current colour wins
        XCTAssertEqual(LampRules.openCentre(current: CGPoint(x: 0, y: 0), recents: [CGPoint(x: 188, y: 0)], half: half),
                       CGPoint(x: 0, y: 0))
        // nothing set, nothing recent: the middle of the wheel
        XCTAssertEqual(LampRules.openCentre(current: nil, recents: [], half: half), .zero)
        // nothing set (a colour from elsewhere): the recents
        XCTAssertEqual(LampRules.openCentre(current: nil, recents: [CGPoint(x: 94, y: 40)], half: half), CGPoint(x: 94, y: 40))
    }

    func testSwitchOnMemoryKeepsYourLightButNotTheNightLight() {
        XCTAssertNil(LampRules.memory(of: state(on: false, dim: 60)))
        let warm = LampRules.memory(of: state(on: true, dim: 35, temp: 2200))
        XCTAssertEqual(warm?["dimming"] as? Int, 35)
        XCTAssertEqual(warm?["temp"] as? Int, 2200)
        XCTAssertNil(warm?["state"])
        var night = state(on: true, dim: 10, temp: nil)
        night.rgb = (255, 28, 0)
        XCTAssertNil(LampRules.memory(of: night))                      // the night light is not a memory
        var blue = state(on: true, dim: 50, temp: nil)
        blue.rgb = (0, 80, 255)
        XCTAssertEqual(LampRules.memory(of: blue)?["b"] as? Int, 255)

        let on = LampRules.switchOn(memory: warm)
        XCTAssertEqual(on["state"] as? Bool, true)
        XCTAssertEqual(on["dimming"] as? Int, 35)
        XCTAssertEqual(LampRules.switchOn(memory: nil).count, 1)        // nothing remembered: just on
        XCTAssertEqual(LampRules.switchOn(memory: ["state": false, "dimming": 20])["state"] as? Bool, true)
    }

    func testWindDownNeverSwitchesOnAndLeavesColour() {
        XCTAssertNil(LampRules.windDown(t: 0.5, start: state(on: true, dim: 80), current: state(on: false, dim: 80)))
        let colour = LampRules.windDown(t: 0.5, start: state(on: true, dim: 80, temp: nil), current: state(on: true, dim: 80, temp: nil))
        XCTAssertNil(colour?["temp"])
        XCTAssertEqual(colour?["dimming"] as? Int, 45)
    }
}

final class PositionRulesTests: XCTestCase {
    func testGPSSaverBelowTwentyPercentWithAGap() {
        XCTAssertEqual(PositionRules.gpsMode(battery: 0.5, charging: false, current: .best), .best)
        XCTAssertEqual(PositionRules.gpsMode(battery: 0.19, charging: false, current: .best), .saver)
        XCTAssertEqual(PositionRules.gpsMode(battery: 0.25, charging: false, current: .saver), .saver)   // no flapping
        XCTAssertEqual(PositionRules.gpsMode(battery: 0.25, charging: false, current: .best), .best)
        XCTAssertEqual(PositionRules.gpsMode(battery: 0.31, charging: false, current: .saver), .best)
        XCTAssertEqual(PositionRules.gpsMode(battery: 0.10, charging: true, current: .saver), .best)    // on the charger
        XCTAssertEqual(PositionRules.gpsMode(battery: nil, charging: false, current: .saver), .saver)   // unknown: keep
    }
}
