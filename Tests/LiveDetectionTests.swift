import XCTest
@testable import Sage

/// Shake to stop, the live onset detector on made-up data, and the wake rule's edges.
final class LiveDetectionTests: XCTestCase {
    /// |a| at 50 Hz: 1 g at rest with a sharp peak of `peak` g at each time in `at`
    private func feed(_ d: inout ShakeDetector, peaks at: [Double], peak: Double, until end: Double) -> [Double] {
        var fired: [Double] = []
        var t = 0.0
        while t < end {
            let m = at.contains { abs($0 - t) < 0.03 } ? peak : 1.0
            if d.add(t: t, magnitude: m) { fired.append(t) }
            t += 0.02
        }
        return fired
    }

    func testFourHardShakesStop() {
        var d = ShakeDetector()
        let fired = feed(&d, peaks: [1.0, 1.4, 1.8, 2.2], peak: 3.2, until: 4)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0], 2.2, accuracy: 0.05)
    }

    func testThreeShakesOrSoftOnesDoNot() {
        var d = ShakeDetector()
        XCTAssertTrue(feed(&d, peaks: [1.0, 1.4, 1.8], peak: 3.2, until: 4).isEmpty)
        d.reset()
        XCTAssertTrue(feed(&d, peaks: [1.0, 1.4, 1.8, 2.2, 2.6], peak: 2.2, until: 4).isEmpty)    // turning over in bed: below 2.5 g
        d.reset()
        XCTAssertTrue(feed(&d, peaks: [1.0, 2.0, 3.0, 4.0], peak: 3.2, until: 5).isEmpty)          // too slow: 1 s apart
    }

    func testOnsetNeedsTenQuietMinutes() {
        var d = OnsetDetector()
        // 20 minutes awake (moving every few seconds), then still
        var onset: Double? = nil
        for s in 0..<(90 * 60) {
            let t = 1_000_000.0 + Double(s)
            let awake = s < 20 * 60
            let sd = awake && s % 5 == 0 ? 0.08 : 0.002
            if let o = d.add(MotionSecond(t: t, sd: sd, gx: 0.1, gy: 0.2, gz: -0.97)) { onset = o; break }
        }
        let o = try? XCTUnwrap(onset)
        // still from minute 20: the quiet verdict needs most of the ±5-minute window still, so the onset lands a few
        // minutes after the movement stops, and is reported 15 minutes later
        XCTAssertNotNil(o)
        if let o { XCTAssertEqual(o, 1_000_000 + 20 * 60, accuracy: 6 * 60) }
    }

    func testOnsetWaitsForAFallingHeartRate() {
        var d = OnsetDetector()
        // up and about at 60 bpm, then lying perfectly still while the heart rate goes up to 75 (something exciting
        // on screen): not sleep
        for s in 0..<(75 * 60) {
            let t = 2_000_000.0 + Double(s)
            let awake = s < 15 * 60
            if s % 5 == 0 { d.addHeart(t: t, bpm: awake ? 60 : 75) }
            let sd = awake && s % 5 == 0 ? 0.08 : 0.002
            XCTAssertNil(d.add(MotionSecond(t: t, sd: sd, gx: 0, gy: 0, gz: -1)), "second \(s)")
        }
    }

    func testWakeRuleWaitsForTheWindowAndClosesIt() {
        var r = WakeRule(onset: 0, opens: 600, closes: 900)
        // stirring before the window: ignored
        for t in 100..<110 { XCTAssertNil(r.second(MotionSecond(t: Double(t), sd: 0.1, gx: 0, gy: 0, gz: -1))) }
        // quiet inside the window, then the latest wake
        var reason: WakeRule.Reason? = nil
        var at = 0.0
        for t in 600...900 {
            if let x = r.second(MotionSecond(t: Double(t), sd: 0.001, gx: 0, gy: 0, gz: -1)) { reason = x; at = Double(t); break }
        }
        XCTAssertEqual(reason, .latest)
        XCTAssertEqual(at, 900)
    }

    func testWakeRuleHearsTheHeartRise() {
        var r = WakeRule(onset: 0, opens: 3600, closes: 7200)
        var got: (Double, WakeRule.Reason)? = nil
        for t in stride(from: 0.0, to: 7200, by: 5) {
            let bpm = t < 4000 ? 55.0 : 66.0
            if let x = r.beat(t: t, bpm: bpm) { got = (t, x); break }
        }
        XCTAssertEqual(got?.1, .heart)
        XCTAssertEqual(got?.0 ?? 0, 4000, accuracy: 120)
    }
}
