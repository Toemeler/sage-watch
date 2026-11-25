import XCTest
@testable import Sage

/// The vibration alarm's settings: ranges, the strength climb, bursts, and the trip to the watch and back.
final class AlarmPatternTests: XCTestCase {
    func testClimbsInEvenStepsAndHoldsThePeak() {
        var s = AlarmSettings()
        s.startLevel = 0
        s.peakLevel = 3
        let ramp = 120.0
        XCTAssertEqual(s.level(at: 0, ramp: ramp), 0)
        XCTAssertEqual(s.level(at: 39.9, ramp: ramp), 0)
        XCTAssertEqual(s.level(at: 40, ramp: ramp), 1)
        XCTAssertEqual(s.level(at: 80, ramp: ramp), 2)
        XCTAssertEqual(s.level(at: 119.9, ramp: ramp), 2)
        XCTAssertEqual(s.level(at: 120, ramp: ramp), 3)
        XCTAssertEqual(s.level(at: 9_999, ramp: ramp), 3)
        XCTAssertEqual(s.level(at: -5, ramp: ramp), 0)
    }

    func testNoRampMeansFullStrengthAtOnce() {
        var s = AlarmSettings()
        s.startLevel = 1
        s.peakLevel = 4
        XCTAssertEqual(s.level(at: 0, ramp: 0), 4)
    }

    func testSameStartAndPeakStaysFlat() {
        var s = AlarmSettings()
        s.startLevel = 2
        s.peakLevel = 2
        for t in stride(from: 0.0, to: 200, by: 7) { XCTAssertEqual(s.level(at: t, ramp: 120), 2) }
    }

    func testClampsEverythingAndKeepsThePeakAboveTheStart() {
        var s = AlarmSettings()
        s.startLevel = 3
        s.peakLevel = 1
        s.rampMinutes = 99
        s.gap = 0.1
        s.taps = 0
        s.testSeconds = 1_000
        s.testDelayMinutes = -4
        let c = s.clamped()
        XCTAssertEqual(c.startLevel, 3)
        XCTAssertEqual(c.peakLevel, 3)
        XCTAssertEqual(c.rampMinutes, AlarmSettings.rampRange.upperBound)
        XCTAssertEqual(c.gap, AlarmSettings.gapRange.lowerBound)
        XCTAssertEqual(c.taps, 1)
        XCTAssertEqual(c.testSeconds, AlarmSettings.testRange.upperBound)
        XCTAssertEqual(c.testDelayMinutes, 0)
        s.gap = .nan
        XCTAssertEqual(s.clamped().gap, 2.5)
    }

    func testBurstsFinishBeforeTheNextPulse() {
        var s = AlarmSettings()
        s.taps = 4
        s.gap = 1
        XCTAssertEqual(s.tapOffsets.count, 4)
        for (got, want) in zip(s.tapOffsets, [0, 0.6, 1.2, 1.8]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
        XCTAssertGreaterThan(s.effectiveGap, s.tapOffsets.last! + 0.5)
        s.taps = 1
        XCTAssertEqual(s.effectiveGap, 1)
        XCTAssertEqual(s.tapOffsets, [0])
    }

    func testTestReachesThePeakWithTimeToSpare() {
        var s = AlarmSettings()
        s.startLevel = 0
        s.peakLevel = 4
        s.gap = 2
        s.testSeconds = 20
        let pulses = s.pulses(length: s.testSeconds, ramp: s.testRamp)
        XCTAssertEqual(pulses.count, 10)
        XCTAssertEqual(pulses.first?.level, 0)
        XCTAssertEqual(pulses.map(\.level), pulses.map(\.level).sorted(), "never gets weaker")
        XCTAssertGreaterThanOrEqual(pulses.filter { $0.level == 4 }.count, 4, "the last 40 % is at full strength")
    }

    func testRoundTripThroughThePropertyList() throws {
        var s = AlarmSettings()
        s.startLevel = 1
        s.peakLevel = 4
        s.rampMinutes = 3.5
        s.gap = 1.5
        s.taps = 3
        s.testSeconds = 45
        s.testDelayMinutes = 5
        // the same trip WatchConnectivity makes: property-list bytes and back
        let data = try PropertyListSerialization.data(fromPropertyList: s.dictionary, format: .binary, options: 0)
        let back = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(AlarmSettings(dictionary: back), s)
    }

    func testMissingOrBrokenValuesFallBackToDefaults() {
        XCTAssertEqual(AlarmSettings(dictionary: nil), AlarmSettings())
        XCTAssertEqual(AlarmSettings(dictionary: ["gap": "fast", "taps": [1]]), AlarmSettings())
        XCTAssertEqual(AlarmSettings(dictionary: ["taps": 2]).taps, 2)
    }

    func testSavesAndLoads() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AlarmPatternTests"))
        defaults.removePersistentDomain(forName: "AlarmPatternTests")
        XCTAssertEqual(AlarmSettings.load(defaults), AlarmSettings())
        var s = AlarmSettings()
        s.peakLevel = 4
        s.taps = 2
        s.save(defaults)
        XCTAssertEqual(AlarmSettings.load(defaults), s)
        defaults.removePersistentDomain(forName: "AlarmPatternTests")
    }

    func testLevelNames() {
        XCTAssertEqual(AlarmLevel.name(0), "Click")
        XCTAssertEqual(AlarmLevel.name(4), "Buzz")
        XCTAssertEqual(AlarmLevel.name(9), "Buzz")
        XCTAssertEqual(AlarmLevel.name(-1), "Click")
    }
}
