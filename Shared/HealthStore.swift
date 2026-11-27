import Foundation
import HealthKit

/// Steps and heart rate from HealthKit. Degrades gracefully: when HealthKit is unavailable (for example inside
/// LiveContainer, which runs the app without its own entitlements) the values stay nil and the face shows a dash.
@MainActor
final class HealthStore: ObservableObject {
    @Published private(set) var steps: Int?
    @Published private(set) var heartRate: Int?
    @Published private(set) var available = false
    /// why steps or heart rate are missing, in plain words (nil when everything reads fine)
    @Published private(set) var problem: String?

    private let store = HKHealthStore()
    private var timer: Timer?

    func start() async {
        guard HKHealthStore.isHealthDataAvailable(),
              let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        // On the watch the recorder asks for Health access at the same moment; if this request loses that race it
        // throws, but the access granted through the other request still lets the queries read. So never give up here.
        do {
            try await store.requestAuthorization(toShare: [], read: [stepType, hrType])
        } catch {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                try await store.requestAuthorization(toShare: [], read: [stepType, hrType])
            } catch {
                problem = "Health access failed: \(error.localizedDescription)"
            }
        }
        available = true
        await refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        let (s, stepError) = await todaySteps()
        let (hr, hrError) = await latestHeartRate()
        if let s { steps = s }
        if let hr { heartRate = hr }
        if let e = stepError ?? hrError {
            problem = e
        } else if s != nil || hr != nil {
            problem = nil
        } else if problem == nil {
            problem = "No steps or heart rate readable yet. Check iPhone Settings › Health › Data Access & Devices › Sage."
        }
    }

    /// a readable error, ignoring "no data yet"
    private static func describe(_ error: Error?, _ what: String) -> String? {
        guard let error else { return nil }
        if let hk = error as? HKError, hk.code == .errorNoData { return nil }
        return "\(what): \(error.localizedDescription)"
    }

    private func todaySteps() async -> (Int?, String?) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return (nil, nil) }
        let start = Calendar.current.startOfDay(for: .now)
        let pred = HKQuery.predicateForSamples(withStart: start, end: .now)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: pred, options: .cumulativeSum) { _, stats, error in
                // split up: Xcode 26's type checker times out on the one-line form
                var steps: Int? = nil
                if let sum: HKQuantity = stats?.sumQuantity() { steps = Int(sum.doubleValue(for: HKUnit.count())) }
                let problem: String? = Self.describe(error, "Steps")
                cont.resume(returning: (steps, problem))
            }
            store.execute(q)
        }
    }

    private func latestHeartRate() async -> (Int?, String?) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return (nil, nil) }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                let perMinute: HKUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
                let bpm: Double? = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: perMinute)
                var value: Int? = nil
                if let b: Double = bpm { value = Int(b.rounded()) }
                let problem: String? = Self.describe(error, "Heart rate")
                cont.resume(returning: (value, problem))
            }
            store.execute(q)
        }
    }
}
