import Combine
import Foundation

// MARK: - Deltas

/// The most-recently computed per-source IR delta percentages.
/// Positive = increased resistance, negative = decreased. Zero = no effect.
struct AppleHealthIRDeltas: Sendable {
    var sleep: Double = 0
    var steps: Double = 0
    var hrv: Double = 0
    var exercise: Double = 0

    var combined: Double { sleep + steps + hrv + exercise }

    /// Returns the delta for a given source — used by UI to avoid switch statements.
    func delta(for source: AppleHealthIRSource) -> Double {
        switch source {
        case .sleep: return sleep
        case .steps: return steps
        case .hrv: return hrv
        case .exercise: return exercise
        }
    }
}

// MARK: - Protocol

protocol AppleHealthIRService: AnyObject {
    /// All logged snapshots, newest first, pruned to last 24 hours.
    var entries: [AppleHealthIREntry] { get }
    /// The most recently computed per-source deltas. Updated on every `update()` call.
    var currentDeltas: AppleHealthIRDeltas { get }
    /// Combined multiplier: 1.0 = no effect, 1.20 = 20% more resistance, 0.92 = 8% less resistance.
    /// Hard floor of 0.5 — algorithm cannot receive a multiplier below that.
    var insulinResistanceMultiplier: Double { get }
    /// Fires whenever entries or the multiplier change.
    var updatePublisher: AnyPublisher<Void, Never> { get }

    /// Called by HomeStateModel+Biometrics whenever BiometricsService fires.
    /// Each call generates fresh snapshot entries and recomputes the multiplier.
    func update(sleepHours: Double?, stepCount: Int, hrv: Double?, exerciseHours: Double?)
}

// MARK: - Implementation

final class BaseAppleHealthIRService: AppleHealthIRService {
    private(set) var entries: [AppleHealthIREntry] = []
    private(set) var currentDeltas = AppleHealthIRDeltas()
    private(set) var insulinResistanceMultiplier: Double = 1.0

    var updatePublisher: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<Void, Never>()
    private let storageKey = "AppleHealthIREntries"
    private let activeWindowHours: Double = 24

    init() {
        load()
        // Multiplier starts from stored entries on launch; recomputed on first update() call.
    }

    // MARK: - Public

    func update(sleepHours: Double?, stepCount: Int, hrv: Double?, exerciseHours: Double?) {
        let now = Date()

        let sleepDelta = Self.computeSleepDelta(sleepHours)
        let stepsDelta = Self.computeStepsDelta(stepCount)
        let hrvDelta = Self.computeHRVDelta(hrv)
        let exerciseDelta = Self.computeExerciseDelta(exerciseHours)

        // Build one entry per non-zero source so every adjustment is individually traceable.
        var newEntries: [AppleHealthIREntry] = []

        if sleepDelta != 0.0, let hours = sleepHours {
            newEntries.append(AppleHealthIREntry(
                timestamp: now,
                source: .sleep,
                irDeltaPercent: sleepDelta,
                details: String(format: "Sleep: %.1f h → %+.1f%% IR", hours, sleepDelta)
            ))
        }

        if stepsDelta != 0.0 {
            newEntries.append(AppleHealthIREntry(
                timestamp: now,
                source: .steps,
                irDeltaPercent: stepsDelta,
                details: String(format: "Activity: %d steps → %+.1f%% IR", stepCount, stepsDelta)
            ))
        }

        if hrvDelta != 0.0, let ms = hrv {
            newEntries.append(AppleHealthIREntry(
                timestamp: now,
                source: .hrv,
                irDeltaPercent: hrvDelta,
                details: String(format: "HRV: %.0f ms → %+.1f%% IR", ms, hrvDelta)
            ))
        }

        if exerciseDelta != 0.0, let exHours = exerciseHours {
            newEntries.append(AppleHealthIREntry(
                timestamp: now,
                source: .exercise,
                irDeltaPercent: exerciseDelta,
                details: String(format: "Exercise: %.0f min → %+.1f%% IR", exHours * 60, exerciseDelta)
            ))
        }

        // Prepend newest entries, then prune window.
        entries = newEntries + entries
        prune()

        // Snapshot current deltas so UI can read them without re-running math.
        currentDeltas = AppleHealthIRDeltas(sleep: sleepDelta, steps: stepsDelta, hrv: hrvDelta, exercise: exerciseDelta)

        // Recompute multiplier from live deltas (not from accumulated entries).
        // Hard floor 0.5 — insulin delivery can never be more than halved.
        insulinResistanceMultiplier = max(0.5, 1.0 + currentDeltas.combined / 100.0)

        save()
        subject.send()
    }

    // MARK: - IR Math
    // All thresholds are documented inline. Values are deterministic and not LLM-derived.

    /// Sleep-driven IR delta.
    /// - < 5 h sleep  → +20% IR (severe deprivation).
    /// - 5–7 h sleep  → linear interpolation from +15% (at 5 h) down to +5% (approaching 7 h).
    ///   Formula: +5.0 + (7.0 - hours) / 2.0 * 10.0
    ///   At 5 h: +5 + 2/2 * 10 = +15; at 6.9 h: +5 + 0.1/2 * 10 = +5.5.
    /// - 7–9 h sleep  → 0% (optimal range).
    /// - > 9 h or nil → 0% (no data or oversleeping, no adjustment).
    private static func computeSleepDelta(_ sleepHours: Double?) -> Double {
        guard let h = sleepHours else { return 0.0 }
        if h < 5 {
            return 20.0
        } else if h < 7 {
            return 5.0 + (7.0 - h) / 2.0 * 10.0
        } else {
            return 0.0
        }
    }

    /// Steps-driven IR delta.
    /// - < 2 000 steps → 0% (insufficient data; sedentary not differentiated from "no data").
    /// - 2 000–4 999   → -3% IR (some activity; mild improvement).
    /// - 5 000–9 999   → -5% IR (moderate activity).
    /// - ≥ 10 000      → -8% IR (high activity; notable sensitivity improvement).
    private static func computeStepsDelta(_ steps: Int) -> Double {
        if steps < 2_000 {
            return 0.0
        } else if steps < 5_000 {
            return -3.0
        } else if steps < 10_000 {
            return -5.0
        } else {
            return -8.0
        }
    }

    /// HRV-driven IR delta.
    /// Low HRV indicates high sympathetic activity (stress/illness) → increased IR.
    /// High HRV indicates good recovery → improved sensitivity.
    /// - nil            → 0% (no data).
    /// - < 20 ms        → +15% IR (very high stress or illness).
    /// - 20–39 ms       → +8% IR (elevated stress).
    /// - 40–60 ms       → 0% (normal range).
    /// - > 60 ms        → -5% IR (excellent recovery / low stress).
    private static func computeHRVDelta(_ hrv: Double?) -> Double {
        guard let ms = hrv else { return 0.0 }
        if ms < 20 {
            return 15.0
        } else if ms < 40 {
            return 8.0
        } else if ms <= 60 {
            return 0.0
        } else {
            return -5.0
        }
    }

    /// Exercise-driven IR delta (uses Apple Exercise Minutes from HealthKit).
    /// Exercise improves insulin sensitivity, so all non-zero deltas are negative.
    /// - nil / 0 min     → 0% (no exercise data recorded today).
    /// - < 20 min        → 0% (below Apple's official "exercise" threshold; treated as incidental).
    /// - 20–59 min       → -5% IR (one moderate session).
    /// - 60–119 min      → -10% IR (substantial training load).
    /// - ≥ 120 min       → -15% IR (heavy training day; effect capped here).
    private static func computeExerciseDelta(_ exerciseHours: Double?) -> Double {
        guard let h = exerciseHours else { return 0.0 }
        let minutes = h * 60
        if minutes < 20 {
            return 0.0
        } else if minutes < 60 {
            return -5.0
        } else if minutes < 120 {
            return -10.0
        } else {
            return -15.0
        }
    }

    // MARK: - Persistence (UserDefaults JSON)

    private func prune() {
        let cutoff = Date().addingTimeInterval(-activeWindowHours * 3_600)
        entries = entries.filter { $0.timestamp > cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([AppleHealthIREntry].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-activeWindowHours * 3_600)
        entries = decoded.filter { $0.timestamp > cutoff }
    }
}
