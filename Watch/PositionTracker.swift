import CoreLocation
import CoreMotion
import Foundation

/// Position tracking on the watch, alongside a recording run ("Track position" in the long-press menu):
/// every GPS fix (best accuracy, no distance filter), Apple's step counter with floors up/down, and absolute
/// altitude (GPS + barometer). The compass/orientation stream comes from the recorder's own motion manager
/// (heading.csv), the relative barometer from its pressure.csv. Each stream is a RotatingCSV in the run's segment,
/// shipped to the iPhone like the others. Battery: GPS all day is expensive; the switch is off by default.
final class PositionTracker: NSObject, CLLocationManagerDelegate {
    static let shared = PositionTracker()

    private let queue = DispatchQueue(label: "sage.position", qos: .utility)
    private lazy var opQueue: OperationQueue = {
        let q = OperationQueue()
        q.underlyingQueue = queue
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var manager: CLLocationManager?            // main thread
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    // owned by queue
    private var locationFile: RotatingCSV?
    private var stepsFile: RotatingCSV?
    private var altitudeFile: RotatingCSV?
    private(set) var running = false
    /// the last fix, for the menu (main thread)
    private(set) var lastFix: CLLocation?
    var onFix: ((CLLocation) -> Void)?

    /// starts all position streams into the run's segment directory (main thread)
    func start(directory dir: URL, segment: String) {
        guard !running else { return }
        running = true
        let period = RecordingFormat.chunkSeconds
        queue.async {
            self.locationFile = RotatingCSV(directory: dir, prefix: PositionFormat.location, header: PositionFormat.locationHeader,
                                            period: period, segment: segment)
            self.stepsFile = RotatingCSV(directory: dir, prefix: PositionFormat.steps, header: PositionFormat.stepsHeader,
                                         period: period, segment: segment)
            self.altitudeFile = RotatingCSV(directory: dir, prefix: PositionFormat.altitude, header: PositionFormat.altitudeHeader,
                                            period: period, segment: segment)
        }

        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.distanceFilter = kCLDistanceFilterNone
        m.activityType = .otherNavigation
        // keep fixes coming while Sage is in the background; only allowed with the location background mode
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String], modes.contains("location") {
            m.allowsBackgroundLocationUpdates = true
        }
        manager = m
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() }
        m.startUpdatingLocation()

        if CMPedometer.isStepCountingAvailable() {
            let since = Date()
            pedometer.startUpdates(from: since) { [weak self] data, _ in
                guard let self, let d = data else { return }
                let line = PositionFormat.steps(t: d.endDate.timeIntervalSince1970, steps: d.numberOfSteps.intValue,
                                                distance: d.distance?.doubleValue, up: d.floorsAscended?.intValue,
                                                down: d.floorsDescended?.intValue, cadence: d.currentCadence?.doubleValue,
                                                pace: d.currentPace?.doubleValue)
                self.queue.async { self.stepsFile?.append(line, at: d.endDate.timeIntervalSince1970) }
            }
        }
        if #available(watchOS 8.0, *), CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: opQueue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                let t = Date().timeIntervalSince1970
                self.altitudeFile?.append(PositionFormat.altitude(t: t, altitude: d.altitude, accuracy: d.accuracy, precision: d.precision), at: t)
            }
        }
    }

    /// stops and ships what is open (main thread)
    func stop() {
        guard running else { return }
        running = false
        manager?.stopUpdatingLocation()
        manager = nil
        pedometer.stopUpdates()
        if #available(watchOS 8.0, *) { altimeter.stopAbsoluteAltitudeUpdates() }
        queue.async {
            self.locationFile?.close(); self.stepsFile?.close(); self.altitudeFile?.close()
            self.locationFile = nil; self.stepsFile = nil; self.altitudeFile = nil
        }
    }

    /// closes the open chunks so they reach the iPhone now ("Send now")
    func shipOpenChunks() {
        queue.async { self.locationFile?.close(); self.stepsFile?.close(); self.altitudeFile?.close() }
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations {
            let t = l.timestamp.timeIntervalSince1970
            let line = PositionFormat.location(t: t, lat: l.coordinate.latitude, lon: l.coordinate.longitude, alt: l.altitude,
                                               hAcc: l.horizontalAccuracy, vAcc: l.verticalAccuracy, speed: l.speed,
                                               course: l.course, floor: l.floor?.level)
            queue.async { self.locationFile?.append(line, at: t) }
        }
        if let last = locations.last {
            DispatchQueue.main.async { self.lastFix = last; self.onFix?(last) }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if running, manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
