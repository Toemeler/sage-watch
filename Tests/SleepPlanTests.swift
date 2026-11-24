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
