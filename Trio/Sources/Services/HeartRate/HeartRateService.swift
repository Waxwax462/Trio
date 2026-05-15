import Combine
import Foundation
import HealthKit
import Swinject

// MARK: - Protocol

protocol HeartRateService: AnyObject {
    /// Most recent heart rate in BPM, or nil if unavailable / not authorized.
    var currentBPM: Double? { get }
    /// True when no HealthKit sample has arrived within the staleness threshold.
    var isStale: Bool { get }
    /// Ordered oldest-to-newest window of the last 60 seconds of HR samples.
    var hrWindow: [HRSample] { get }
    /// Derived stress points from hrWindow (BPM/min derivative).
    var stressPoints: [StressPoint] { get }
    /// Current authorization status.
    var authorizationStatus: HRAuthorizationStatus { get }

    /// Publisher that fires whenever any of the above properties change.
    var updatePublisher: AnyPublisher<Void, Never> { get }

    /// Request HealthKit read authorization and start streaming.
    func start() async throws
    /// Stop the HealthKit query (call when app moves to background).
    func stop()
}

// MARK: - Implementation

final class BaseHeartRateService: HeartRateService, Injectable {
    @Injected() private var healthKitStore: HKHealthStore!

    // MARK: Published state (all mutations dispatched to MainActor)

    private(set) var currentBPM: Double?
    private(set) var isStale = false
    private(set) var hrWindow: [HRSample] = []
    private(set) var stressPoints: [StressPoint] = []
    private(set) var authorizationStatus: HRAuthorizationStatus = .notDetermined

    var updatePublisher: AnyPublisher<Void, Never> { updateSubject.eraseToAnyPublisher() }

    // MARK: Private

    private let updateSubject = PassthroughSubject<Void, Never>()
    private var anchoredQuery: HKAnchoredObjectQuery?
    private var anchor: HKQueryAnchor?
    private var ringBuffer = RingBuffer<HRSample>(capacity: 60)

    // Apple Watch background HR fires every 1–5 min; 5 min gives comfortable headroom.
    private let stalenessThreshold: TimeInterval = 300
    private var stalenessTimer: Timer?

    private static let hrType = HKQuantityType(.heartRate)
    private static let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    // MARK: - Public API

    func start() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HeartRateServiceError.healthKitUnavailable
        }
        // Request read authorization if not yet asked. HealthKit doesn't expose
        // read-denial status to apps (privacy), so we proceed after the prompt
        // regardless; a denied user simply receives no samples from the query.
        if healthKitStore.authorizationStatus(for: Self.hrType) == .notDetermined {
            try await healthKitStore.requestAuthorization(toShare: [], read: [Self.hrType])
        }
        await MainActor.run {
            authorizationStatus = .authorized
            startQuery()
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let query = anchoredQuery {
                healthKitStore.stop(query)
                anchoredQuery = nil
            }
            stalenessTimer?.invalidate()
            stalenessTimer = nil
        }
    }

    // MARK: - Query (call on MainActor)

    private func startQuery() {
        // Stop any existing query before starting a new one.
        if let existing = anchoredQuery {
            healthKitStore.stop(existing)
            anchoredQuery = nil
        }
        // Look back 5 min so the initial handler immediately returns the most recent sample.
        let lookback = Date().addingTimeInterval(-300)
        let predicate = HKQuery.predicateForSamples(withStart: lookback, end: nil)
        let query = HKAnchoredObjectQuery(
            type: Self.hrType,
            predicate: predicate,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            self?.handleResults(samples: samples, newAnchor: newAnchor, error: error)
        }
        query.updateHandler = { [weak self] _, samples, _, newAnchor, error in
            self?.handleResults(samples: samples, newAnchor: newAnchor, error: error)
        }
        anchoredQuery = query
        healthKitStore.execute(query)
    }

    private func handleResults(
        samples: [HKSample]?,
        newAnchor: HKQueryAnchor?,
        error: Error?
    ) {
        if let error {
            debug(.service, "HeartRateService query error: \(error.localizedDescription)")
            return
        }
        anchor = newAnchor
        guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else { return }
        let newSamples = quantitySamples
            .sorted { $0.endDate < $1.endDate }
            .map { HRSample(bpm: $0.quantity.doubleValue(for: Self.bpmUnit), timestamp: $0.endDate) }
        Task { @MainActor [weak self] in
            self?.ingestSamples(newSamples)
        }
    }

    // MARK: - State update (always called on MainActor)

    @MainActor
    private func ingestSamples(_ samples: [HRSample]) {
        for sample in samples {
            ringBuffer.append(sample)
        }
        let windowSamples = ringBuffer.elements
        hrWindow = windowSamples
        stressPoints = windowSamples.stressDerivative()
        currentBPM = windowSamples.last?.bpm
        isStale = false
        resetStalenessTimer()
        updateSubject.send()
    }

    @MainActor
    private func resetStalenessTimer() {
        stalenessTimer?.invalidate()
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: stalenessThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isStale = true
                self?.updateSubject.send()
            }
        }
    }
}
