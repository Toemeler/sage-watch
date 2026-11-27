import XCTest
@testable import Sage

final class ChartZoomTests: XCTestCase {
    let day = 0.0...86400.0

    func testZoomKeepsThePointUnderTheFingers() {
        let r = ChartZoom.zoom(day, full: day, scale: 4, anchor: 0.5, minSpan: 600)
        XCTAssertEqual(r.upperBound - r.lowerBound, 21600, accuracy: 1e-6)       // 24 h / 4
        XCTAssertEqual((r.lowerBound + r.upperBound) / 2, 43200, accuracy: 1e-6) // noon stays in the middle
        let left = ChartZoom.zoom(day, full: day, scale: 2, anchor: 0, minSpan: 600)
        XCTAssertEqual(left.lowerBound, 0, accuracy: 1e-6)                          // the left edge stays put
    }

    func testZoomStopsAtTheLimits() {
        let tight = ChartZoom.zoom(day, full: day, scale: 1e6, anchor: 0.3, minSpan: 600)
        XCTAssertEqual(tight.upperBound - tight.lowerBound, 600, accuracy: 1e-6)   // never narrower than 10 min
        let out = ChartZoom.zoom(1000.0...2000.0, full: day, scale: 1e-6, anchor: 0.5, minSpan: 600)
        XCTAssertEqual(out, day)                                                      // never wider than the day
    }

    func testPanStaysInsideTheDay() {
        let r = ChartZoom.pan(80000.0...86000.0, full: day, fraction: 1)
        XCTAssertEqual(r, 80400.0...86400.0)
        let l = ChartZoom.pan(100.0...700.0, full: day, fraction: -1)
        XCTAssertEqual(l, 0.0...600.0)
    }

    func testThinKeepsEverySampleWhenFew() {
        let pts = (0..<5000).map { (Double($0) * 5, $0) }                           // 5-s heart samples
        XCTAssertEqual(ChartZoom.thin(pts, in: 0...3600).count, 721)                // one hour: all of them
        XCTAssertLessThanOrEqual(ChartZoom.thin(pts, in: 0...25000, limit: 900).count, 900)
    }
}
