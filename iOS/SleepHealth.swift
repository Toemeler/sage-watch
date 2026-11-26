import Foundation
import HealthKit

/// Apple Health's sleep: when you fell asleep and woke (very accurate, Apple's own detection on the watch) and its
/// stages (core, deep, REM, awake). Sage uses the times as the sleep window when they exist and shows the stages
/// next to its own estimate. Without access, or for a sleep Apple did not record (naps), Sage's own detection is used.
enum SleepHealth {
    struct Sample: Codable, Equatable {
        var start: Double
        var end: Double
        /// "asleep", "core", "deep", "rem", "awake", "inBed"
        var value: String
        var isAsleep: Bool { value != "awake" && value != "inBed" }
    }

    private static let store = HKHealthStore()
    private static var type: HKCategoryType? { HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) }

    /// asks once; afterwards the system remembers the answer (reading never says whether it was granted)
    static func requestAccess() async {
        guard HKHealthStore.isHealthDataAvailable(), let type else { return }
        try? await store.requestAuthorization(toShare: [], read: [type])
    }

    /// every sleep sample overlapping [from, to), oldest first (empty without access or data)
    static func samples(from: Date, to: Date) async -> [Sample] {
        guard HKHealthStore.isHealthDataAvailable(), let type else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                let out = (samples as? [HKCategorySample] ?? []).map {
                    Sample(start: $0.startDate.timeIntervalSince1970, end: $0.endDate.timeIntervalSince1970, value: name($0.value))
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    static func name(_ value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: return "inBed"
        case .awake: return "awake"
        case .asleepCore: return "core"
        case .asleepDeep: return "deep"
        case .asleepREM: return "rem"
        default: return "asleep"
        }
    }

    /// the asleep span that overlaps [lo, hi): first asleep sample's start to last asleep sample's end, when the
    /// asleep samples cover at least half of what Sage found (so a short Apple record never shrinks a long sleep)
    static func asleepSpan(_ samples: [Sample], around lo: Double, _ hi: Double) -> (onset: Double, wake: Double)? {
        let asleep = samples.filter { $0.isAsleep && $0.end > lo - 3600 && $0.start < hi + 3600 }
        guard let first = asleep.map(\.start).min(), let last = asleep.map(\.end).max(), last > first else { return nil }
        let covered = asleep.reduce(0.0) { $0 + ($1.end - $1.start) }
        guard covered >= 0.5 * (hi - lo) else { return nil }
        return (first, last)
    }
}
