import XCTest
@testable import Sage

/// The night analysis against tools/night_reference.py on a real night (26 Nov 2026, Tests/Fixtures).
/// The fixtures and night_expected.json come from tools/make_fixtures.py; regenerate both when the algorithm changes.
final class NightAnalysisTests: XCTestCase {
    struct Fixture {
        let seconds: SecondSeries
        let heart: HeartSeries
        let grid: Grid10
        let expected: [String: Any]
        var lo: Double { expected["lo"] as! Double }
        var hi: Double { expected["hi"] as! Double }
    }

    static let fixture: Fixture? = {
        guard let seconds = try? csv("night_seconds.csv.zz", columns: [0, 1, 2, 3, 4]),
              let heart = try? csv("night_heart.csv.zz", columns: [0, 1]),
              let gridData = try? load("night_grid10.f32.zz"),
              let json = try? load("night_expected.json", compressed: false),
              let expected = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let floats = gridData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = floats.count / 3
        let x = (0..<n).map { Double(floats[3 * $0]) }, y = (0..<n).map { Double(floats[3 * $0 + 1]) }, z = (0..<n).map { Double(floats[3 * $0 + 2]) }
        return Fixture(seconds: SecondSeries(t: seconds[0], sd: seconds[1], gx: seconds[2], gy: seconds[3], gz: seconds[4]),
                       heart: HeartSeries(t: heart[0], bpm: heart[1]),
                       grid: Grid10(start: expected["grid_start"] as! Double, x: x, y: y, z: z),
                       expected: expected)
    }()

    static func load(_ name: String, compressed: Bool = true) throws -> Data {
        let bundle = Bundle(for: NightAnalysisTests.self)
        guard let dir = bundle.url(forResource: "Fixtures", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        return compressed ? try (data as NSData).decompressed(using: .zlib) as Data : data
    }

    static func csv(_ name: String, columns: [Int]) throws -> [[Double]] {
        CSVNumbers.read(try load(name), columns: columns)
    }

    private func fixture() throws -> Fixture {
        try XCTUnwrap(Self.fixture, "fixtures missing from the test bundle")
    }

    // MARK: resampling and breathing

    func testResamplerMatchesReference() throws {
        let raw = try Self.csv("raw_excerpt.csv.zz", columns: [0, 1, 2, 3])
        let expectedData = try Self.load("raw_excerpt_grid.f32.zz")
        let exp = expectedData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let f = try fixture()
        let g = Grid10(t: raw[0], x: raw[1], y: raw[2], z: raw[3])
        XCTAssertEqual(g.start, f.expected["excerpt_grid_start"] as! Double, accuracy: 1e-6)
        XCTAssertEqual(g.count, f.expected["excerpt_grid_count"] as! Int)
        XCTAssertEqual(exp.count, g.count * 3)
        for i in 0..<g.count {
            for (k, v) in [g.x[i], g.y[i], g.z[i]].enumerated() {
                let e = Double(exp[3 * i + k])
                if e.isNaN { XCTAssertTrue(v.isNaN, "bin \(i)"); continue }
                XCTAssertEqual(v, e, accuracy: 1e-5, "bin \(i) axis \(k)")
            }
        }
    }

    func testBuilderMatchesResampler() throws {
        let raw = try Self.csv("raw_excerpt.csv.zz", columns: [0, 1, 2, 3])
        let g = Grid10(t: raw[0], x: raw[1], y: raw[2], z: raw[3])
        var b = Grid10Builder(from: raw[0][0], to: raw[0].last! + 0.1)
        let half = raw[0].count / 2                                 // in two pieces, as chunks arrive
        b.add(t: Array(raw[0][..<half]), x: Array(raw[1][..<half]), y: Array(raw[2][..<half]), z: Array(raw[3][..<half]))
        b.add(t: Array(raw[0][half...]), x: Array(raw[1][half...]), y: Array(raw[2][half...]), z: Array(raw[3][half...]))
        let h = b.finish()
        XCTAssertEqual(h.start, g.start, accuracy: 1e-9)
        for i in 0..<g.count {
            if g.x[i].isNaN { XCTAssertTrue(h.x[i].isNaN); continue }
            XCTAssertEqual(h.x[i], g.x[i], accuracy: 1e-12)
            XCTAssertEqual(h.z[i], g.z[i], accuracy: 1e-12)
        }
    }

    func testBreathingFindsASyntheticRhythm() {
        for perMinute in [9.0, 15.0, 22.0] {
            let n = 900
            let x = (0..<n).map { i in 0.003 * sin(2 * .pi * perMinute / 60 * Double(i) / 10) }
            let g = Grid10(start: 0, x: x, y: Array(repeating: 0.2, count: n), z: Array(repeating: -0.97, count: n))
            XCTAssertEqual(Breathing.rate(g, from: 100), perMinute, accuracy: 0.3, "\(perMinute)/min")
        }
        // the arm moving: no estimate
        let moving = (0..<900).map { i in 0.1 * sin(Double(i) / 3) }
        let g = Grid10(start: 0, x: moving, y: moving, z: moving)
        XCTAssertTrue(Breathing.rate(g, from: 0).isNaN)
        // a gap: no estimate
        var gap = Array(repeating: 0.0, count: 900)
        gap[300] = .nan
        XCTAssertTrue(Breathing.rate(Grid10(start: 0, x: gap, y: gap, z: gap), from: 0).isNaN)
    }

    // MARK: the real night

    private func compare(_ a: NightAnalysis, _ e: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.onset, e["onset"] as! Double, accuracy: 0.001, "onset", file: file, line: line)
        XCTAssertEqual(a.wake, e["wake"] as! Double, accuracy: 0.001, "wake", file: file, line: line)

        let stages = e["stage"] as! [Int]
        XCTAssertEqual(a.stage.count, stages.count, file: file, line: line)
        let same = zip(a.stage, stages).filter { $0.0.rawValue == $0.1 }.count
        XCTAssertGreaterThanOrEqual(Double(same) / Double(max(1, stages.count)), 0.99, "stage agreement \(same)/\(stages.count)", file: file, line: line)

        let breaths = e["breaths"] as! [Any]
        var validBoth = 0, validDiffer = 0
        for (k, v) in breaths.enumerated() where k < a.breaths.count {
            let mine = a.breaths[k]
            if let ref = v as? Double {
                if mine.isNaN { validDiffer += 1 } else {
                    validBoth += 1
                    XCTAssertEqual(mine, ref, accuracy: 0.01, "breaths epoch \(k)", file: file, line: line)
                }
            } else if !mine.isNaN { validDiffer += 1 }
        }
        XCTAssertGreaterThan(validBoth, 300, file: file, line: line)
        XCTAssertLessThanOrEqual(validDiffer, 3, file: file, line: line)

        let cycles = e["cycles"] as! [[String: Any]]
        XCTAssertEqual(a.cycles.count, cycles.count, "cycles", file: file, line: line)
        for (c, r) in zip(a.cycles, cycles) {
            XCTAssertEqual(c.start, r["start"] as! Double, accuracy: 61, file: file, line: line)
            XCTAssertEqual(c.end, r["end"] as! Double, accuracy: 61, file: file, line: line)
            XCTAssertEqual(c.complete, r["complete"] as! Bool, file: file, line: line)
        }

        let s = e["summary"] as! [String: Any]
        XCTAssertEqual(a.summary.minutes, s["minutes"] as! Double, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(a.summary.hrMean ?? .nan, s["hr_mean"] as! Double, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.summary.hrMin ?? .nan, s["hr_min"] as! Double, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.summary.hrLow5 ?? .nan, s["hr_low5"] as! Double, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.summary.hrLow5At ?? .nan, s["hr_low5_at"] as! Double, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.summary.breaths ?? .nan, s["breaths"] as! Double, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(a.summary.bursts, s["bursts"] as! Int, file: file, line: line)
        let refStages = s["stages"] as! [Double]
        for i in 0..<4 { XCTAssertEqual(a.summary.stages[i], refStages[i], accuracy: 3, "stage \(i) minutes", file: file, line: line) }
    }

    func testFindsTheNightOnItsOwn() throws {
        let f = try fixture()
        let a = try XCTUnwrap(NightAnalysis.analyze(seconds: f.seconds, heart: f.heart, grid: f.grid, charging: [], from: f.lo, to: f.hi))
        compare(a, f.expected["auto"] as! [String: Any])
        // Apple Health: fell asleep 01:11. Sage on its own: within two minutes of that.
        let health = 1_795_651_860.0     // 2026-11-26 01:11 Europe/Zurich
        XCTAssertEqual(a.onset, health, accuracy: 120)
    }

    func testWithAppleHealthTimes() throws {
        let f = try fixture()
        let e = f.expected["fixed"] as! [String: Any]
        let a = try XCTUnwrap(NightAnalysis.analyze(seconds: f.seconds, heart: f.heart, grid: f.grid, charging: [], from: f.lo, to: f.hi,
                                                    onset: e["onset"] as? Double, wake: e["wake"] as? Double))
        compare(a, e)
        // three full cycles of about an hour and a half, and the bit before the alarm
        XCTAssertEqual(a.completeCycles.count, 3)
        for c in a.completeCycles { XCTAssertTrue((65...120).contains(c.minutes), "\(c.minutes) min") }
    }

    func testSleepPeriodsFindTheNight() throws {
        let f = try fixture()
        let periods = NightAnalysis.sleepPeriods(seconds: f.seconds, charging: [], from: f.lo, to: f.hi)
        let auto = f.expected["auto"] as! [String: Any]
        XCTAssertTrue(periods.contains { abs($0.onset - (auto["onset"] as! Double)) < 1 }, "\(periods)")
    }

    func testChargingIsNotSleep() throws {
        let f = try fixture()
        // the whole range on the charger: nothing counts as sleep
        let charging = stride(from: f.lo, to: f.hi, by: 60).map { $0 }
        XCTAssertNil(NightAnalysis.analyze(seconds: f.seconds, heart: f.heart, grid: nil, charging: charging, from: f.lo, to: f.hi))
    }

    // MARK: live detection, replayed

    private enum Ev { case second(Int), beat(Int) }

    /// seconds and heart samples in time order; at equal times seconds first (as the reference sorts them)
    private func events(_ f: Fixture) -> [(Double, Ev)] {
        var ev: [(Double, Int, Ev)] = []
        for i in 0..<f.seconds.count { ev.append((f.seconds.t[i], 0, .second(i))) }
        for i in 0..<f.heart.count { ev.append((f.heart.t[i], 1, .beat(i))) }
        ev.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return ev.map { ($0.0, $0.2) }
    }

    private func second(_ f: Fixture, _ i: Int) -> MotionSecond {
        MotionSecond(t: f.seconds.t[i], sd: f.seconds.sd[i], gx: f.seconds.gx[i], gy: f.seconds.gy[i], gz: f.seconds.gz[i])
    }

    func testLiveOnsetMatchesReference() throws {
        let f = try fixture()
        let live = f.expected["live"] as! [String: Any]
        var d = OnsetDetector()
        var found: (Double, Double)? = nil
        for (t, e) in events(f) {
            switch e {
            case .beat(let i): d.addHeart(t: t, bpm: f.heart.bpm[i])
            case .second(let i):
                if let o = d.add(second(f, i)) { found = (o, t) }
            }
            if found != nil { break }
        }
        let (onset, confirmed) = try XCTUnwrap(found)
        XCTAssertEqual(onset, live["onset"] as! Double, accuracy: 0.001)
        XCTAssertEqual(confirmed, live["confirmed"] as! Double, accuracy: 0.001)
    }

    func testNapAndMorningWakeMatchReference() throws {
        let f = try fixture()
        let live = f.expected["live"] as! [String: Any]
        let onset = live["onset"] as! Double
        for (key, opens, closes) in [("nap", onset + 70 * 60, onset + 100 * 60),
                                     ("morning", 1_795_669_200.0, 1_795_671_000.0)] {     // 06:00 – 06:30
            let exp = live[key] as! [String: Any]
            var rule = WakeRule(onset: onset, opens: opens, closes: closes)
            var result: (Double, WakeRule.Reason)? = nil
            for (t, e) in events(f) {
                switch e {
                case .beat(let i):
                    if t < onset { rule.remember(t: t, bpm: f.heart.bpm[i]); continue }
                    if let r = rule.beat(t: t, bpm: f.heart.bpm[i]) { result = (t, r) }
                case .second(let i):
                    if t < onset { continue }
                    if let r = rule.second(second(f, i)) { result = (t, r) }
                }
                if result != nil { break }
            }
            let (t, reason) = try XCTUnwrap(result, key)
            XCTAssertEqual(t, exp["time"] as! Double, accuracy: 0.001, key)
            XCTAssertEqual(reason.rawValue, exp["reason"] as! String, key)
        }
        // in plain words: the nap rule would have woken you at 02:41:20, where your first cycle ended (02:44)
        XCTAssertEqual((live["nap"] as! [String: Any])["time"] as! Double, 1_795_657_280.0, accuracy: 1)
    }

    // MARK: cycles

    func testCycleBoundsKeepCyclesInRange() {
        let onset = 0.0, wake = 6 * 3600.0
        // candidates at 50 min (too early for a cycle), 90, 140 (only 50 min after 90, and 140 min after falling
        // asleep), 185 and 270: the only chain with every cycle 65–120 min long is 90 → 185 → 270, even though
        // 140 scores highest
        let c: [(Double, Double)] = [(50 * 60, 2), (90 * 60, 1.5), (140 * 60, 3), (185 * 60, 1), (270 * 60, 0.8)]
        let b = NightAnalysis.cycleBounds(c, onset: onset, wake: wake)
        XCTAssertEqual(b.map { $0 / 60 }, [90, 185, 270])
        XCTAssertEqual(NightAnalysis.cycleBounds([], onset: 0, wake: 100 * 60), [])
    }

    func testTroughProminence() {
        let x: [Double] = [0, 1, 0.5, 2, 0.2, 0.3, 0]
        let peaks = NightAnalysis.troughsWithProminence(x)
        XCTAssertEqual(peaks.map(\.0), [1, 3, 5])
        XCTAssertEqual(peaks[0].1, 0.5, accuracy: 1e-12)     // 1 - max(0, 0.5)
        XCTAssertEqual(peaks[1].1, 2.0, accuracy: 1e-12)
        XCTAssertEqual(peaks[2].1, 0.1, accuracy: 1e-12)
    }
}
