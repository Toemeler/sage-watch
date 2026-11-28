import XCTest
@testable import Sage

final class ProbeFormatTests: XCTestCase {
    func testStreamNamesHaveNoUnderscore() {
        // chunk names are "<stream>_<stamp>.csv": an underscore in a stream name would break stream(ofFile:)
        for s in ProbeFormat.all {
            XCTAssertFalse(s.contains("_"), s)
            XCTAssertEqual(RecordingFormat.stream(ofFile: "\(s)_20261128-120000.csv"), s)
        }
    }

    func testEveryStreamHasAHeaderStartingWithTime() {
        for s in ProbeFormat.all {
            XCTAssertTrue(ProbeFormat.header(of: s).hasPrefix("unix_"), s)
        }
    }

    func testShortType() {
        XCTAssertEqual(ProbeFormat.shortType("HKQuantityTypeIdentifierHeartRate"), "HeartRate")
        XCTAssertEqual(ProbeFormat.shortType("HKCategoryTypeIdentifierSleepAnalysis"), "SleepAnalysis")
        XCTAssertEqual(ProbeFormat.shortType("Custom"), "Custom")
    }

    func testFieldHasNoCommas() {
        XCTAssertEqual(ProbeFormat.field("Tom's Watch, Ultra\n2"), "Tom's Watch; Ultra 2")
    }

    func testWaveRoundTrip() {
        let values: [Float] = [0.98, 1.02, 1.5, 0]
        XCTAssertEqual(ProbeLink.unpackWave(ProbeLink.packWave(values)), values)
        XCTAssertEqual(ProbeLink.unpackWave(Data()), [])
    }

    func testCoreMotionTimeFix() {
        // device motion: seconds since boot
        XCTAssertEqual(RecordingFormat.unixTime(logTimestamp: 1000, bootOffset: 1_700_000_000), 1_700_001_000)
        // the altimeter on watchOS 27: seconds since 2001
        XCTAssertEqual(RecordingFormat.unixTime(logTimestamp: 800_000_000, bootOffset: 5), 1_778_307_200)
    }

    func testStreamDataReadsChunksInOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let header = ProbeFormat.pressureHeader
        try "\(header)\n10.000,101.3,0.0\n11.000,101.2,0.1\n".write(to: dir.appendingPathComponent("probe-baro_20261128-120000.csv"), atomically: true, encoding: .utf8)
        try "\(header)\n12.000,101.1,0.2\n".write(to: dir.appendingPathComponent("probe-baro_20261128-120200.csv"), atomically: true, encoding: .utf8)
        let d = ProbeStreamData.load(segment: dir, stream: ProbeFormat.pressure)
        XCTAssertEqual(d.totalLines, 3)
        XCTAssertEqual(d.rows.map { $0[0] }, ["10.000", "11.000", "12.000"])
        XCTAssertEqual(d.numericColumns, [1, 2])
        XCTAssertEqual(d.series(column: 1).map(\.1), [101.3, 101.2, 101.1])
    }

    func testValueDisplay() {
        XCTAssertEqual(ProbeValue.number(72).display, "72.00")
        XCTAssertEqual(ProbeValue.number(1013.31).display, "1013.3")
        XCTAssertEqual(ProbeValue.number(0.5).display, "0.5000")
        XCTAssertEqual(ProbeValue.text("charging").display, "charging")
    }
}
