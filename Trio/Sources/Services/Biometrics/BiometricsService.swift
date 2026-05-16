import Combine
import Foundation
import HealthKit

enum BiometricsAuthorizationStatus: Sendable {
    case notDetermined
    case authorized
    case denied
}

final class BiometricsService: @unchecked Sendable {
    private let healthKitStore = HKHealthStore()
    let updatePublisher = PassthroughSubject<Void, Never>()

    private(set) var stepCount: Int = 0
    private(set) var hrv: Double? = nil
    private(set) var sleepHours: Double? = nil
    private(set) var exerciseHours: Double? = nil
    private(set) var authorizationStatus: BiometricsAuthorizationStatus = .notDetermined

    private var stepObserverQuery: HKObserverQuery?
    private var exerciseObserverQuery: HKObserverQuery?
    private var hrvAnchoredQuery: HKAnchoredObjectQuery?
    private var hrvAnchor: HKQueryAnchor?
    private var isStarted = false

    private static let stepType = HKQuantityType(.stepCount)
    private static let exerciseType = HKQuantityType(.appleExerciseTime)
    private static let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
    private static let sleepType = HKCategoryType(.sleepAnalysis)
    private static let hrvUnit = HKUnit.secondUnit(with: .milli)

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationStatus = .denied
            completion(false)
            return
        }
        let readTypes: Set<HKObjectType> = [Self.stepType, Self.exerciseType, Self.hrvType, Self.sleepType]
        healthKitStore.requestAuthorization(toShare: [], read: readTypes) { [weak self] success, _ in
            DispatchQueue.main.async {
                self?.authorizationStatus = success ? .authorized : .denied
            }
            completion(success)
        }
    }

    func startMonitoring() {
        requestAuthorization { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isStarted {
                    // Already running — only refresh one-shot queries
                    self.fetchTodaySteps(completion: nil)
                    self.fetchTodayExercise(completion: nil)
                    self.fetchSleep()
                    return
                }
                self.isStarted = true
                self.startStepQuery()
                self.startExerciseQuery()
                self.startHRVQuery()
                self.fetchSleep()
            }
        }
    }

    func stopMonitoring() {
        guard isStarted else { return }
        isStarted = false
        if let q = stepObserverQuery { healthKitStore.stop(q); stepObserverQuery = nil }
        if let q = exerciseObserverQuery { healthKitStore.stop(q); exerciseObserverQuery = nil }
        if let q = hrvAnchoredQuery { healthKitStore.stop(q); hrvAnchoredQuery = nil }
    }

    func refreshSleep() {
        fetchSleep()
    }

    // MARK: - Steps

    private func startStepQuery() {
        guard stepObserverQuery == nil else {
            fetchTodaySteps(completion: nil)
            return
        }
        let query = HKObserverQuery(sampleType: Self.stepType, predicate: nil) { [weak self] _, completionHandler, error in
            guard error == nil else { completionHandler(); return }
            self?.fetchTodaySteps(completion: completionHandler)
        }
        stepObserverQuery = query
        healthKitStore.execute(query)
        fetchTodaySteps(completion: nil)
    }

    private func fetchTodaySteps(completion: (@Sendable () -> Void)?) {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date())
        let statsQuery = HKStatisticsQuery(
            quantityType: Self.stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { [weak self] _, result, _ in
            let steps = Int(result?.sumQuantity()?.doubleValue(for: .count()) ?? 0)
            Task { @MainActor [weak self] in
                self?.stepCount = steps
                self?.updatePublisher.send()
            }
            completion?()
        }
        healthKitStore.execute(statsQuery)
    }

    // MARK: - Exercise

    private func startExerciseQuery() {
        guard exerciseObserverQuery == nil else {
            fetchTodayExercise(completion: nil)
            return
        }
        let query = HKObserverQuery(sampleType: Self.exerciseType, predicate: nil) { [weak self] _, completionHandler, error in
            guard error == nil else { completionHandler(); return }
            self?.fetchTodayExercise(completion: completionHandler)
        }
        exerciseObserverQuery = query
        healthKitStore.execute(query)
        fetchTodayExercise(completion: nil)
    }

    private func fetchTodayExercise(completion: (@Sendable () -> Void)?) {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date())
        let statsQuery = HKStatisticsQuery(
            quantityType: Self.exerciseType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { [weak self] _, result, _ in
            let minutes = result?.sumQuantity()?.doubleValue(for: .minute()) ?? 0
            // Store nil when no exercise data exists (avoids treating 0 as "no data")
            let hours: Double? = minutes > 0 ? minutes / 60.0 : nil
            Task { @MainActor [weak self] in
                self?.exerciseHours = hours
                self?.updatePublisher.send()
            }
            completion?()
        }
        healthKitStore.execute(statsQuery)
    }

    // MARK: - HRV

    private func startHRVQuery() {
        if let existing = hrvAnchoredQuery { healthKitStore.stop(existing); hrvAnchoredQuery = nil }
        let lookback = Date().addingTimeInterval(-86400)
        let predicate = HKQuery.predicateForSamples(withStart: lookback, end: nil)
        let query = HKAnchoredObjectQuery(
            type: Self.hrvType,
            predicate: predicate,
            anchor: hrvAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            self?.handleHRVResults(samples: samples, newAnchor: newAnchor, error: error)
        }
        query.updateHandler = { [weak self] _, samples, _, newAnchor, error in
            self?.handleHRVResults(samples: samples, newAnchor: newAnchor, error: error)
        }
        hrvAnchoredQuery = query
        healthKitStore.execute(query)
    }

    private func handleHRVResults(samples: [HKSample]?, newAnchor: HKQueryAnchor?, error: Error?) {
        guard error == nil,
              let qty = samples as? [HKQuantitySample],
              !qty.isEmpty
        else { return }
        hrvAnchor = newAnchor
        let value = qty.sorted { $0.endDate < $1.endDate }.last?.quantity.doubleValue(for: Self.hrvUnit)
        Task { @MainActor [weak self] in
            self?.hrv = value
            self?.updatePublisher.send()
        }
    }

    // MARK: - Sleep

    func fetchSleep() {
        let calendar = Calendar.current
        let now = Date()
        guard let windowStart = calendar.date(byAdding: .hour, value: -12, to: calendar.startOfDay(for: now)),
              let windowEnd = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: now))
        else { return }

        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(
            sampleType: Self.sleepType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDescriptor]
        ) { [weak self] _, samples, _ in
            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue
            ]
            let totalSeconds = (samples as? [HKCategorySample])?
                .filter { asleepValues.contains($0.value) }
                .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } ?? 0
            let hours = totalSeconds > 0 ? totalSeconds / 3600 : nil
            Task { @MainActor [weak self] in
                self?.sleepHours = hours
                self?.updatePublisher.send()
            }
        }
        healthKitStore.execute(query)
    }
}
