import Foundation

/// Sunrise and sunset from the date and a rough position (NOAA's approximation, within ~2 min at mid latitudes;
/// the sun at -0.833°, as almanacs give it). Used by the arrival light (F16) to know whether it is dark.
enum Sun {
    /// sunrise and sunset on the local day of `date`; nil where the sun does not rise or set that day
    static func times(on date: Date, lat: Double, lon: Double, calendar: Calendar = .current) -> (rise: Date, set: Date)? {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let midnight = utc.date(from: day), let n = utc.ordinality(of: .day, in: .year, for: midnight) else { return nil }
        let g = 2 * Double.pi / 365 * Double(n - 1)
        let eq = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g) + 0.000907 * sin(2 * g)
            - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        let la = lat * .pi / 180
        let c = cos(90.833 * .pi / 180) / (cos(la) * cos(decl)) - tan(la) * tan(decl)
        guard c.isFinite, abs(c) <= 1 else { return nil }
        let ha = acos(c) * 180 / .pi
        let rise = 720 - 4 * (lon + ha) - eq, set = 720 - 4 * (lon - ha) - eq     // minutes after UTC midnight
        return (midnight.addingTimeInterval(rise * 60), midnight.addingTimeInterval(set * 60))
    }

    /// is it dark at `date`? With no position known: dark from 17:00 to 07:00, right for winter evenings; a summer
    /// evening would count as dark too early, so the watch keeps a rough position from its last GPS fix
    static func dark(at date: Date, lat: Double?, lon: Double?, calendar: Calendar = .current) -> Bool {
        if let lat, let lon, let t = times(on: date, lat: lat, lon: lon, calendar: calendar) {
            return date < t.rise || date > t.set
        }
        let h = calendar.component(.hour, from: date)
        return h >= 17 || h < 7
    }
}
