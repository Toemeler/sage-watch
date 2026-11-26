import WidgetKit
import SwiftUI

/// Complications for Apple's own watch faces: what comes next in the sleep plan.
struct NextEntry: TimelineEntry {
    let date: Date
    let mode: FaceMode
    let sleepBlock: Plan.Block
    let sleepAt: Date
    let window: Plan.WakeWindow
}

struct NextProvider: TimelineProvider {
    func entry(_ d: Date) -> NextEntry {
        let next = Plan.nextSleep(after: d)
        return NextEntry(date: d, mode: FaceMode.auto(d), sleepBlock: next.block, sleepAt: next.at, window: Plan.nextWakeWindow(after: d))
    }
    func placeholder(in context: Context) -> NextEntry { entry(.now) }
    func getSnapshot(in context: Context, completion: @escaping (NextEntry) -> Void) { completion(entry(.now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEntry>) -> Void) {
        // one entry every 5 minutes for 6 hours: countdowns stay honest without draining the budget
        let start = Date.now
        let entries = (0..<72).map { entry(start.addingTimeInterval(Double($0) * 300)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct NextView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextEntry

    private var asleep: Bool { entry.mode == .sleeping || entry.mode == .nap }
    private var minutesToSleep: Int { max(0, Int(entry.sleepAt.timeIntervalSince(entry.date) / 60)) }
    private var title: String { entry.sleepBlock == .nap ? "Nap" : "Sleep" }
    private var countdown: String { String(format: "%d:%02d", minutesToSleep / 60, minutesToSleep % 60) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            if asleep {
                VStack(spacing: 0) {
                    Image(systemName: "moon.zzz")
                    Text(Plan.fmt(Plan.dayClock(entry.window.predicted))).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
            } else {
                Gauge(value: Double(min(minutesToSleep, 360)), in: 0...360) {
                    Image(systemName: entry.sleepBlock == .nap ? "powersleep" : "moon")
                } currentValueLabel: {
                    Text(countdown).monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(asleep ? "Smart wake" : "\(title) \(Plan.fmt(Plan.dayClock(entry.sleepAt)))")
                    .font(.headline).widgetAccentable()
                if asleep && entry.window.block == .nap {
                    Text("one cycle").monospacedDigit()
                    Text("after you fall asleep").foregroundStyle(.secondary)
                } else if asleep {
                    Text("\(Plan.fmt(Plan.dayClock(entry.window.start)))–\(Plan.fmt(Plan.dayClock(entry.window.end)))").monospacedDigit()
                    Text("light sleep, silent taps").foregroundStyle(.secondary)
                } else if entry.sleepBlock == .nap {
                    Text("in \(minutesToSleep / 60)h \(String(format: "%02d", minutesToSleep % 60))m").monospacedDigit()
                    Text("wakes after one cycle").foregroundStyle(.secondary)
                } else {
                    Text("in \(minutesToSleep / 60)h \(String(format: "%02d", minutesToSleep % 60))m").monospacedDigit()
                    Text("wake \(Plan.fmt(Plan.dayClock(entry.window.predicted)))").foregroundStyle(.secondary)
                }
            }
        #if os(watchOS)
        case .accessoryCorner:
            Image(systemName: entry.sleepBlock == .nap ? "powersleep" : "moon")
                .widgetLabel { Text(asleep ? "wake \(Plan.fmt(Plan.dayClock(entry.window.predicted)))" : "\(title) in \(countdown)") }
        #endif
        default:
            Text(asleep ? "Wake \(Plan.fmt(Plan.dayClock(entry.window.predicted)))" : "\(title) in \(countdown)")
        }
    }
}

struct SageNext: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SageNext", provider: NextProvider()) { entry in
            NextView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Sage · next")
        .description("Countdown to the nap or the night, and the smart-wake window while you sleep.")
        #if os(watchOS)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
        #endif
    }
}

@main
struct SageComplicationsBundle: WidgetBundle {
    var body: some Widget { SageNext() }
}
