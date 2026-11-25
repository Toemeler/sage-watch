import XCTest
@testable import Sage

/// The recorder's file format: per-second motion summary, time filtering, stream names and export ranges.
final class RecordingFormatTests: XCTestCase {
    func testSummaryEmitsOneLinePerSecond() {
        var s = MotionSummarizer()
        var lines: [String] = []
        for i in 0..<100 {                                   // 2 s at 50 Hz, wrist still, gravity on -z
            let t = 1_000.0 + Double(i) / 50
            if let line = s.add(t: t, x: 0, y: 0, z: -1) { lines.append(line) }
        }
        if let last = s.flush() { lines.append(last) }
        XCTAssertEqual(lines.count, 2)
        let first = lines[0].split(separator: ",")
        XCTAssertEqual(first[0], "1000")
        XCTAssertEqual(first[1], "50")
        XCTAssertEqual(Double(first[2])!, 1, accuracy: 1e-9)     // mean |a| = 1 g
        XCTAssertEqual(Double(first[3])!, 0, accuracy: 1e-9)     // no movement
        XCTAssertEqual(Double(first[6])!, -1, accuracy: 1e-9)    // mean z
        XCTAssertEqual(Double(first[7])!, 0, accuracy: 1e-9)     // activity
    }

    func testSummaryActivityCountsMovement() {
        var s = MotionSummarizer()
        _ = s.add(t: 5.0, x: 0, y: 0, z: 1)
        _ = s.add(t: 5.5, x: 0, y: 0, z: 1.5)
        let line = s.flush()!.split(separator: ",")
        XCTAssertEqual(Double(line[7])!, 0.5, accuracy: 1e-9)
        XCTAssertNil(s.flush())
    }

    func testLinesAreCutToTheRange() {
        let csv = "\(RecordingFormat.heartHeader)\n10.0,10.0,60\n20.000,20.0,61\n30.5,30.5,62\nbroken\n"
        let kept = RecordingFormat.lines(in: csv, from: 15, to: 30.5)
        XCTAssertEqual(kept.map(String.init), ["20.000,20.0,61", "30.5,30.5,62"])
    }

    func testStreamFromFileName() {
        XCTAssertEqual(RecordingFormat.stream(ofFile: "hr_20261125-170012.csv"), "hr")
        XCTAssertEqual(RecordingFormat.stream(ofFile: "motion1s_20261125-170012.csv"), "motion1s")
        XCTAssertNil(RecordingFormat.stream(ofFile: "segment.json"))
    }

    func testLastNightRangeCoversThePlannedNight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 10))!
        let r = ExportRange.lastNight.interval(now: now, calendar: cal)
        let start = cal.dateComponents([.day, .hour, .minute], from: r.start)
        let end = cal.dateComponents([.day, .hour, .minute], from: r.end)
        XCTAssertEqual(start.day, 24); XCTAssertEqual(start.hour, 21); XCTAssertEqual(start.minute, 30)
        XCTAssertEqual(end.day, 25); XCTAssertEqual(end.hour, 9); XCTAssertEqual(end.minute, 0)
    }

    func testLastNapRangeBeforeTodaysNapIsYesterdays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!
        let r = ExportRange.lastNap.interval(now: now, calendar: cal)
        let start = cal.dateComponents([.day, .hour], from: r.start)
        XCTAssertEqual(start.day, 24)
        XCTAssertEqual(start.hour, 16)
    }

    func testCompactStepsFitTheSubdial() {
        XCTAssertEqual(FaceRenderer.compactSteps(8431), "8,431")
        XCTAssertEqual(FaceRenderer.compactSteps(12161), "12.2k")
    }

    func testBatteryPercent() {
        XCTAssertNil(FaceRenderer.batteryPercent(-1))
        XCTAssertEqual(FaceRenderer.batteryPercent(0.836), 84)
        XCTAssertEqual(FaceRenderer.batteryPercent(1), 100)
        XCTAssertEqual(FaceRenderer.batteryPercent(0), 0)
    }
}
