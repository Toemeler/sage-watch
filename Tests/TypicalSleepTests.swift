import XCTest
@testable import Sage

/// The lamp's wind-down follows the average of recorded sleep, including nights that start either side of midnight.
final class TypicalSleepTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return c
    }()

    private func t(_ day: Int, _ h: Int, _ m: Int) -> Double {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!.timeIntervalSince1970
    }

    func testNightAveragesAcrossMidnight() {
        // 23:50 and 00:30 average to 00:10 (night clock 1450), not to noon
        let nights = [(t(20, 23, 50), t(21, 6, 10)), (t(22, 0, 30), t(22, 6, 30))]
        let s = TypicalSleep.from(naps: [], nights: nights, calendar: cal)
        XCTAssertEqual(s.nightOnset ?? 0, 1450.0, accuracy: 0.5)       // 00:10
        XCTAssertEqual(s.nightWake ?? 0, 1820.0, accuracy: 0.5)        // 06:20
        XCTAssertNil(s.napOnset)
    }

    func testNeedsTwoRecordings() {
        let one = TypicalSleep.from(naps: [(t(20, 17, 10), t(20, 18, 40))], nights: [], calendar: cal)
        XCTAssertNil(one.napOnset)
        XCTAssertEqual(one.napCount, 1)
        let two = TypicalSleep.from(naps: [(t(20, 17, 10), t(20, 18, 40)), (t(21, 16, 50), t(21, 18, 20))], nights: [], calendar: cal)
        XCTAssertEqual(two.napOnset ?? 0, 1020.0, accuracy: 0.5)
        XCTAssertEqual(two.napWake ?? 0, 1110.0, accuracy: 0.5)
    }

    func testDictionaryRoundTrip() {
        var s = TypicalSleep()
        s.napOnset = 1020; s.napWake = 1110; s.napCount = 3; s.nightOnset = 1470; s.nightWake = 1830; s.nightCount = 5
        XCTAssertEqual(TypicalSleep(dictionary: s.dictionary), s)
    }
}
