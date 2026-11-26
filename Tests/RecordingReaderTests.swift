import XCTest
@testable import Sage

/// The byte-level CSV reader and the chunk store.
final class RecordingReaderTests: XCTestCase {
    func testReadsColumnsSkipsHeadersAndBadLines() {
        let text = "unix_time,x,y,z\n100.5,0.1,-0.2,0.9\nbroken line\n101,,0.3,\n102,1e-3,2,3"   // no final newline
        let c = CSVNumbers.read(Data(text.utf8), columns: [0, 1, 3])
        XCTAssertEqual(c[0], [100.5, 101, 102])
        XCTAssertEqual(c[1][0], 0.1)
        XCTAssertTrue(c[1][1].isNaN)                    // empty field stays empty, never the next line's number
        XCTAssertEqual(c[1][2], 0.001)
        XCTAssertTrue(c[2][1].isNaN)
        XCTAssertEqual(c[2][2], 3)
    }

    func testRangeAndTextColumns() {
        let text = "unix_time,battery,battery_state\n10,0.9,unplugged\n20,0.8,charging\n30,0.7,full\n"
        let c = CSVNumbers.read(Data(text.utf8), columns: [0, 1, 2], from: 15, to: 30)
        XCTAssertEqual(c[0], [20])
        XCTAssertEqual(c[1], [0.8])
        XCTAssertTrue(c[2][0].isNaN)
        let rows = CSVNumbers.rows(Data(text.utf8), from: 15)
        XCTAssertEqual(rows.map { String($0[2]) }, ["charging", "full"])
    }

    func testStoreMergesChunksInOrderAndDropsRepeats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("20261126-005236"), b = root.appendingPathComponent("20261126-073252")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let t0 = try XCTUnwrap(RecordingFormat.openedAt("hr_20261126-010000.csv"))
        func write(_ dir: URL, _ name: String, _ lines: [Double]) throws {
            let body = "unix_start,unix_end,bpm\n" + lines.map { "\($0),\($0),60" }.joined(separator: "\n") + "\n"
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write(a, "hr_20261126-010000.csv", [t0 + 5, t0 + 10, t0 + 15])
        try write(a, "hr_20261126-011000.csv", [t0 + 600, t0 + 605])
        try write(b, "hr_20261126-011000.csv", [t0 + 605, t0 + 610])        // a re-sent overlap
        try "x".write(to: a.appendingPathComponent("segment.json"), atomically: true, encoding: .utf8)
        let store = RecordingStore(root: root)
        XCTAssertEqual(store.chunks(stream: "hr").count, 3)
        let c = store.numbers("hr", columns: [0, 2], from: t0, to: t0 + 3600)
        XCTAssertEqual(c[0], [t0 + 5, t0 + 10, t0 + 15, t0 + 600, t0 + 605, t0 + 610])
        let late = store.numbers("hr", columns: [0], from: t0 + 601, to: t0 + 3600)
        XCTAssertEqual(late[0], [t0 + 605, t0 + 610])
        XCTAssertEqual(store.chunks(stream: "hr", from: t0 + 3 * 3600, to: t0 + 4 * 3600).count, 0)
    }

    func testOpenedAtReadsEventNames() {
        let a = RecordingFormat.openedAt("events_20261126-060104-123-ring.csv")
        let b = RecordingFormat.openedAt("events_20261126-060104.csv")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(RecordingFormat.stream(ofFile: "events_20261126-060104-123-ring.csv"), "events")
        XCTAssertNil(RecordingFormat.openedAt("hr_2026.csv"))
    }

    func testSummarizerReportsTheSecondAsNumbers() {
        var s = MotionSummarizer()
        for i in 0..<60 { _ = s.add(t: 50 + Double(i) / 50, x: 0, y: 0.6, z: -0.8) }
        _ = s.add(t: 51.5, x: 0, y: 0.6, z: -0.8)
        let sec = s.lastSecond
        XCTAssertEqual(sec?.t, 50)
        XCTAssertEqual(sec?.sd ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(sec?.gy ?? 0, 0.6, accuracy: 1e-9)
    }
}
