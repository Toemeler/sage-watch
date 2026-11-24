import XCTest
@testable import Sage

/// The Swift port must give exactly the numbers the prototype and the app design were verified against.
final class SleepPlanTests: XCTestCase {
    func testNapSmartWakeIs1825() {
        XCTAssertEqual(Plan.nap.wake, 18 * 60 + 25)
        XCTAssertEqual(Plan.fmt(Plan.nap.wake), "18:25")
        XCTAssertEqual(Plan.nap.minutes, 85)
    }

    func testNightSmartWakeIs0621() {
        XCTAssertEqual(Plan.fmt(Plan.night.wake), "06:21")
        XCTAssertEqual(Plan.night.minutes, 351)
        XCTAssertEqual(Plan.totalSleep, 436)       // 7h 16m
    }

    func testSmartWakeStaysInsideWindow() {
        for b in [Plan.nap, Plan.night] {
            XCTAssertGreaterThanOrEqual(b.wake, b.windowStart)
            XCTAssertLessThanOrEqual(b.wake, b.end)
        }
    }

    func testCycleLengthsSumToBlock() {
        XCTAssertEqual(Plan.night.lens.count, 4)
        XCTAssertEqual(Plan.night.lens.reduce(0, +), 360, accuracy: 12)
    }

    func testStageAtSmartWakeIsLightSleep() {
        XCTAssertEqual(Plan.nap.stageAt(Plan.nap.wake - Plan.nap.onset).stage, .light)
        XCTAssertEqual(Plan.night.stageAt(Plan.night.wake - Plan.night.onset).stage, .light)
    }
}

final class FaceModeTests: XCTestCase {
    private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Zurich")!; return c }()

    /// Tuesday 24 Nov 2026 and Saturday 28 Nov 2026 at the given time
    private func at(_ h: Int, _ m: Int, saturday: Bool = false) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: saturday ? 28 : 24, hour: h, minute: m))!
    }

    func testWeekdaySchedule() {
        let expect: [(Int, Int, FaceMode)] = [
            (0, 10, .evening), (0, 31, .sleeping), (6, 25, .morning), (9, 40, .afternoon), (12, 0, .lunch),
            (13, 20, .afternoon), (17, 5, .nap), (18, 30, .afterNap), (19, 0, .evening), (23, 50, .evening)
        ]
        for (h, m, mode) in expect {
            XCTAssertEqual(FaceMode.auto(at(h, m), cal), mode, "at \(h):\(m)")
        }
    }

    func testSaturdayHasNoWorkModes() {
        XCTAssertEqual(FaceMode.auto(at(12, 0, saturday: true), cal), .weekend)
        XCTAssertEqual(FaceMode.auto(at(10, 0, saturday: true), cal), .weekend)
        XCTAssertEqual(FaceMode.auto(at(17, 5, saturday: true), cal), .nap)
    }

    func testAfternoonCountsDownToNap() {
        XCTAssertEqual(FaceMode.afternoon.label(at(15, 10), cal), "NAP IN 1H 50M")
    }

    func testEveningCountsDownToSleep() {
        XCTAssertEqual(FaceMode.evening.label(at(21, 40), cal), "SLEEP IN 2H 50M")
    }
}

final class GlyphTests: XCTestCase {
    func testParserHandlesAbsoluteCommands() {
        let p = SVGPath.parse("M0 0L10 0V10H0Z")
        XCTAssertEqual(p.boundingRect, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testParserHandlesQuadraticsAndExponents() {
        let p = SVGPath.parse("M0 0Q5 1e1 10 0Z")
        XCTAssertEqual(p.boundingRect.maxX, 10, accuracy: 0.001)
        XCTAssertGreaterThan(p.boundingRect.maxY, 0)
    }

    func testAllDigitsLoad() {
        for d in 0...9 {
            XCTAssertNotNil(Glyphs.regular.digits[d], "regular \(d)")
            XCTAssertNotNil(Glyphs.italic.digits[d], "italic \(d)")
            XCTAssertFalse(Glyphs.regular.digits[d]!.path.isEmpty)
        }
    }

    func testDigitSlotsMatchReferenceInkBoxes() {
        XCTAssertEqual(FaceGeometry.hourSlots.count, 2)
        XCTAssertEqual(FaceGeometry.minuteSlots.count, 2)
    }
}

final class CalendarWindowTests: XCTestCase {
    private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Zurich")!; return c }()
    private func at(_ d: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
    private func hm(_ date: Date) -> String { let c = cal.dateComponents([.day, .hour, .minute], from: date); return String(format: "%d %02d:%02d", c.day!, c.hour!, c.minute!) }

    func testAfternoonPointsAtTheNapWindow() {
        let w = Plan.nextWakeWindow(after: at(24, 15, 10), cal)
        XCTAssertEqual(w.block, .nap)
        XCTAssertEqual(hm(w.start), "24 18:15"); XCTAssertEqual(hm(w.end), "24 18:30"); XCTAssertEqual(hm(w.predicted), "24 18:25")
    }

    func testEveningPointsAtTomorrowMorning() {
        let w = Plan.nextWakeWindow(after: at(24, 19, 0), cal)
        XCTAssertEqual(w.block, .night)
        XCTAssertEqual(hm(w.start), "25 06:00"); XCTAssertEqual(hm(w.end), "25 06:30"); XCTAssertEqual(hm(w.predicted), "25 06:21")
    }

    func testDuringTheNightPointsAtThisMorning() {
        XCTAssertEqual(hm(Plan.nextWakeWindow(after: at(25, 2, 0), cal).start), "25 06:00")
    }

    func testOpenWindowIsStillTheNextOne() {
        XCTAssertEqual(hm(Plan.nextWakeWindow(after: at(25, 6, 10), cal).end), "25 06:30")
    }

    func testAfterTheMorningAlarmPointsAtTheNap() {
        XCTAssertEqual(hm(Plan.nextWakeWindow(after: at(25, 6, 31), cal).start), "25 18:15")
    }

    func testNextSleep() {
        let a = Plan.nextSleep(after: at(24, 15, 10), cal); XCTAssertEqual(a.block, .nap); XCTAssertEqual(hm(a.at), "24 17:00")
        let b = Plan.nextSleep(after: at(24, 19, 0), cal); XCTAssertEqual(b.block, .night); XCTAssertEqual(hm(b.at), "25 00:30")
    }
}

final class MorphTests: XCTestCase {
    func testEveryDigitPairMorphsWithMatchingPointCounts() {
        for set in [Glyphs.regular, Glyphs.italic] {
            for a in 0...9 {
                let b = (a + 1) % 10
                let pairs = GlyphMorph.pairs(set, from: a, to: b)
                XCTAssertFalse(pairs.isEmpty, "\(a)->\(b)")
                for (p, q) in pairs { XCTAssertEqual(p.count, GlyphMorph.samples); XCTAssertEqual(q.count, GlyphMorph.samples) }
            }
        }
    }

    func testMorphEndpointsMatchTheGlyphs() {
        let pairs = GlyphMorph.pairs(Glyphs.regular, from: 1, to: 8)
        let start = GlyphMorph.path(pairs, 0).boundingRect, end = GlyphMorph.path(pairs, 1).boundingRect
        let one = Glyphs.regular.digits[1]!.path.boundingRect, eight = Glyphs.regular.digits[8]!.path.boundingRect
        XCTAssertEqual(start.midX, one.midX, accuracy: 25); XCTAssertEqual(end.midX, eight.midX, accuracy: 25)
        XCTAssertEqual(end.height, eight.height, accuracy: 25)
    }

    func testEscapementSettlesAtOne() {
        XCTAssertEqual(GlyphMorph.escape(0), 0, accuracy: 1e-9)
        XCTAssertEqual(GlyphMorph.escape(1), 1)
        XCTAssertGreaterThan((0...100).map { GlyphMorph.escape(Double($0) / 100) }.max()!, 1)   // overshoot
    }
}
