import Foundation

/// The smart alarm's log. Each event goes to the iPhone at once as a tiny file of its own, filed with the running
/// recording (or under "events" when nothing records), so it survives a crash, an update or a watch switched off.
enum EventLog {
    typealias Event = AlarmEvent

    static let fallbackSegment = "events"

    static func log(_ event: Event, _ detail: String = "", at time: Date = Date()) {
        let t = time.timeIntervalSince1970
        let clean = detail.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
        let text = "\(RecordingFormat.eventsHeader)\n\(RecordingFormat.unix(t)),\(event.rawValue),\(clean)\n"
        // unique name: the stamp (seconds) plus milliseconds and the event, so two events in one second never collide
        let ms = Int((Date().timeIntervalSince1970 * 1000).truncatingRemainder(dividingBy: 1000))
        let name = "\(RecordingFormat.eventsPrefix)_\(RecordingFormat.stamp(Date(), "yyyyMMdd-HHmmss"))-\(String(format: "%03d", ms))-\(event.rawValue).csv"
        Outbox.shared.shipData(Data(text.utf8), name: name, segment: Recorder.shared.segmentID ?? fallbackSegment)
    }
}
