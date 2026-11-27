import XCTest
@testable import Sage

/// Activity on the face, the last night on the face, the nap and alarm settings, and one block's next window.
final class PersonalTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return c
    }()

    private func at(_ h: Int, _ m: Int, day: Int = 24) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    func testOneFaceAwakeOneAsleep() {
        XCTAssertEqual(FaceMode.auto(at(10, 0), cal), .awake)
        XCTAssertEqual(FaceMode.auto(at(17, 5), cal), .sleeping)     // nap
        XCTAssertEqual(FaceMode.auto(at(2, 0), cal), .sleeping)      // night
    }

    func testLastSleepSummaryRoundTrips() {
        let onset = at(1, 11, day: 26).timeIntervalSince1970, wake = at(6, 1, day: 26).timeIntervalSince1970
        let s = LastSleepSummary(onset: onset, wake: wake, asleepMinutes: 286, cycles: 3, averageCycle: 89)
        XCTAssertEqual(LastSleepSummary(dictionary: s.dictionary), s)
    }

    func testNapLengthFromTheFaceKeepsASensibleWindow() {
        let s = AlarmSettings()                                     // 70...100: a 30-minute window
        XCTAssertEqual(s.napWindow(latest: 100).earliest, 70)
        XCTAssertEqual(s.napWindow(latest: 60).earliest, 30)
        XCTAssertEqual(s.napWindow(latest: 20).earliest, 10)        // never before half the nap
        XCTAssertEqual(s.napWindow(latest: 5).latest, 20)           // shortest
        XCTAssertEqual(s.napWindow(latest: 500).latest, 130)        // longest
        XCTAssertEqual(s.napWindow(latest: 82).latest, 80)          // 5-minute grid
    }

    func testNapAndRingSettings() throws {
        var s = AlarmSettings()
        XCTAssertEqual(s.napEarliest, 70)
        XCTAssertEqual(s.napLatest, 100)
        XCTAssertEqual(s.ringSeconds, 180)
        s.napEarliest = 90
        s.napLatest = 60                                   // latest before earliest: pushed to earliest + 10
        s.ringMinutes = 40
        let c = s.clamped()
        XCTAssertEqual(c.napLatest, 100)
        XCTAssertEqual(c.ringMinutes, 10)
        s = AlarmSettings()
        s.napEarliest = 65
        s.napLatest = 110
        s.ringMinutes = 2
        let data = try PropertyListSerialization.data(fromPropertyList: s.dictionary, format: .binary, options: 0)
        let back = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(AlarmSettings(dictionary: back), s)
        // settings saved by 0.3.9 (without the new keys) keep the defaults
        XCTAssertEqual(AlarmSettings(dictionary: ["start": 1, "peak": 3]).napLatest, 100)
    }

    func testNextWindowOfOneBlock() {
        let night = Plan.nextWakeWindow(after: at(17, 0), block: .night, cal)
        XCTAssertEqual(night.block, .night)
        XCTAssertEqual(night.start, at(6, 0, day: 25))
        XCTAssertEqual(night.end, at(6, 30, day: 25))
        let nap = Plan.nextWakeWindow(after: at(19, 0), block: .nap, cal)
        XCTAssertEqual(nap.start, at(18, 15, day: 25))
        // inside the window: still this one
        XCTAssertEqual(Plan.nextWakeWindow(after: at(6, 10, day: 25), block: .night, cal).start, at(6, 0, day: 25))
    }
}
