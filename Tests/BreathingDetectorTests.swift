import XCTest
@testable import Sage

/// Live breathing: a resting wrist tilted a degree or two by each breath, sampled 10 times a second.
final class BreathingDetectorTests: XCTestCase {
    private func breathe(seconds: Double, perMinute: Double, tiltDegrees: Double = 1.5, noise: Double = 0.002) -> BreathingDetector {
        var d = BreathingDetector()
        var seed: UInt64 = 1
        func jitter() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(UInt64(1) << 53) - 0.5) * noise
        }
        for i in 0..<Int(seconds * BreathingDetector.hz) {
            let t = Double(i) / BreathingDetector.hz
            let a = tiltDegrees * .pi / 180 * sin(2 * .pi * perMinute / 60 * t)
            d.add(x: jitter(), y: sin(a) + jitter(), z: -cos(a) + jitter())
        }
        return d
    }

    func testFindsNormalBreathing() {
        let d = breathe(seconds: 45, perMinute: 15)
        XCTAssertFalse(d.moving)
        XCTAssertEqual(d.breathsPerMinute ?? 0, 15, accuracy: 1)
        XCTAssertGreaterThanOrEqual(d.peaks.count, 6)
    }

    func testFindsSlowAndFastBreathing() {
        XCTAssertEqual(breathe(seconds: 60, perMinute: 6).breathsPerMinute ?? 0, 6, accuracy: 0.7)
        XCTAssertEqual(breathe(seconds: 30, perMinute: 25).breathsPerMinute ?? 0, 25, accuracy: 1.5)
    }

    func testNeedsFifteenSecondsFirst() {
        XCTAssertNil(breathe(seconds: 10, perMinute: 15).breathsPerMinute)
    }

    func testMovementIsNotBreathing() {
        var d = breathe(seconds: 45, perMinute: 15)
        for i in 0..<30 {
            let k = Double(i % 3) * 0.2
            d.add(x: k, y: 0.1 - k, z: -1 + k)
        }
        XCTAssertTrue(d.moving)
        XCTAssertNil(d.breathsPerMinute)
    }

    func testPackRoundTrip() {
        let back = LiveLink.unpack(LiveLink.pack([0.1, -0.2, -0.98, 0.0, 0.5, -0.86]))
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[1].1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(back[0].2, -0.98, accuracy: 1e-6)
    }
}
