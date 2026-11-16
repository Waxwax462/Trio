import Foundation

// MARK: - Vocabulary

enum AutoSettingKind: String, JSON, CaseIterable {
    case basal
    case sensitivity
    case carbRatio
    /// The percentage of a sport profile's recovery phase.
    case sportRecovery

    /// Whether going from `old` to `new` makes Trio deliver more insulin.
    func isMoreInsulin(from old: Double, to new: Double) -> Bool {
        switch self {
        case .basal,
             .sportRecovery:
            return new > old
        case .carbRatio,
             .sensitivity:
            return new < old
        }
    }
}

enum AutoSettingsVerdict: String, JSON {
    case notEnoughData
    /// The observations do not agree on a direction.
    case inconclusive
    case matches
    /// A step is due.
    case change
    /// A step is justified, but the last one is too recent.
    case waiting
    /// The value has reached the edge of the allowed band.
    case atLimit
    /// Steps towards more insulin are paused after a low.
    case frozen
    /// The user undid a change of this value recently.
    case blocked
    /// Another kind of setting is being corrected first.
    case otherKindFirst
    /// Not learned, because Dynamic ISF sets this value on every loop.
    case notAdapted
}

/// Every limit of the learner in one place. The values are deliberately not user-configurable.
struct AutoSettingsLimits: Equatable {
    /// Largest step towards less insulin, as a share of the current value.
    var lessInsulinStep: Double = 0.05
    /// Largest step towards more insulin.
    var moreInsulinStep: Double = 0.025
    /// How far a value may move away from its baseline, in both directions.
    var band: Double = 0.20
    var daysBetweenSteps: Double = 3
    /// Differences below this share of the current value count as a match.
    var basalDeadband: Double = 0.05
    var otherDeadband: Double = 0.10
    var minSamplesBasal: Int = 3
    var minSamplesOther: Int = 5
    /// A step towards more insulin needs this many observations more.
    var extraSamplesForMoreInsulin: Int = 2
    /// Observations must come from at least this many different days.
    var minDays: Int = 3
    /// Share of observations that must lie on the same side of the current value.
    var agreementForLessInsulin: Double = 0.75
    var agreementForMoreInsulin: Double = 0.85
    /// How long steps towards more insulin stay paused after a low.
    var freezeDays: Double = 3
    /// A step towards more insulin this recent is taken back after a low.
    var revertWindowDays: Double = 7
    /// How long a value is left alone after the user undid a change.
    var undoBlockDays: Double = 14
    var lowThreshold: Double = 70
    var severeLowThreshold: Double = 54
    /// Consecutive readings below `lowThreshold` that make a low.
    var lowRunLength: Int = 3

    func deadband(for kind: AutoSettingKind) -> Double {
        kind == .basal || kind == .sportRecovery ? basalDeadband : otherDeadband
    }

    func minSamples(for kind: AutoSettingKind) -> Int {
        kind == .basal || kind == .sportRecovery ? minSamplesBasal : minSamplesOther
    }
}

/// The values a setting can take.
enum AutoSettingsGrid: Equatable {
    case step(Double)
    case values([Double])
}

struct AutoSettingsDecision: Equatable {
    var verdict: AutoSettingsVerdict
    /// The median of the observations.
    var estimate: Double?
    /// The value the next step would set.
    var proposed: Double?
    var sampleCount: Int
    var dayCount: Int
}

// MARK: - Policy

/// Decides whether and how far one value may move. Pure arithmetic: no storage, no clock.
enum AutoSettingsPolicy {
    private static let tolerance = 0.000_5

    static func decide(
        kind: AutoSettingKind,
        current: Double,
        anchor: Double,
        samples: [SettingSample],
        lastChange: Date?,
        blockedUntil: Date?,
        moreInsulinFrozen: Bool,
        grid: AutoSettingsGrid,
        hardRange: ClosedRange<Double>,
        now: Date,
        calendar: Calendar,
        limits: AutoSettingsLimits = AutoSettingsLimits()
    ) -> AutoSettingsDecision {
        let values = samples.map(\.value).sorted()
        let dayCount = Set(samples.map { calendar.startOfDay(for: $0.date) }).count
        var decision = AutoSettingsDecision(
            verdict: .notEnoughData,
            estimate: nil,
            proposed: nil,
            sampleCount: values.count,
            dayCount: dayCount
        )
        guard !values.isEmpty, current > 0, anchor > 0 else { return decision }

        let estimate = median(values)
        decision.estimate = estimate

        guard values.count >= limits.minSamples(for: kind), dayCount >= limits.minDays else { return decision }

        guard abs(estimate - current) >= current * limits.deadband(for: kind) else {
            decision.verdict = .matches
            return decision
        }

        let isMore = kind.isMoreInsulin(from: current, to: estimate)
        if isMore, values.count < limits.minSamples(for: kind) + limits.extraSamplesForMoreInsulin {
            return decision
        }

        let agreeing = values.filter { ($0 - current) * (estimate - current) > 0 }.count
        let required = isMore ? limits.agreementForMoreInsulin : limits.agreementForLessInsulin
        guard Double(agreeing) / Double(values.count) >= required else {
            decision.verdict = .inconclusive
            return decision
        }

        if let blockedUntil, blockedUntil > now {
            decision.verdict = .blocked
            return decision
        }
        if isMore, moreInsulinFrozen {
            decision.verdict = .frozen
            return decision
        }

        // One capped step towards the estimate, inside the band around the baseline.
        let cap = isMore ? limits.moreInsulinStep : limits.lessInsulinStep
        let lowerLimit = max(anchor * (1 - limits.band), hardRange.lowerBound)
        let upperLimit = min(anchor * (1 + limits.band), hardRange.upperBound)
        let direction: Double = estimate > current ? 1 : -1

        let stepped = direction > 0
            ? min(estimate, current * (1 + cap))
            : max(estimate, current * (1 - cap))
        let target = min(max(stepped, lowerLimit), upperLimit)
        guard (target - current) * direction > tolerance else {
            decision.verdict = .atLimit
            return decision
        }

        guard let proposed = quantized(target: target, current: current, estimate: estimate, grid: grid) else {
            // The setting cannot express a difference this small.
            decision.verdict = .matches
            return decision
        }
        guard proposed >= lowerLimit - tolerance, proposed <= upperLimit + tolerance else {
            decision.verdict = .atLimit
            return decision
        }
        decision.proposed = proposed

        if let lastChange, now.timeIntervalSince(lastChange) < limits.daysBetweenSteps * 86400 {
            decision.verdict = .waiting
            return decision
        }

        decision.verdict = .change
        return decision
    }

    /// The value on the grid that gets closest to `target` without going past it. When the grid is
    /// coarser than the step, the neighbouring grid value is taken instead, but only if the
    /// estimate is at least that far away.
    static func quantized(target: Double, current: Double, estimate: Double, grid: AutoSettingsGrid) -> Double? {
        let direction: Double = target > current ? 1 : -1

        var within: Double?
        var neighbour: Double?

        switch grid {
        case let .step(step):
            guard step > 0 else { return nil }
            let onGrid = direction > 0
                ? (target / step + tolerance).rounded(.down) * step
                : (target / step - tolerance).rounded(.up) * step
            if (onGrid - current) * direction > tolerance {
                within = onGrid
            }
            neighbour = direction > 0
                ? (current / step + tolerance).rounded(.down) * step + step
                : (current / step - tolerance).rounded(.up) * step - step

        case let .values(values):
            let sorted = values.sorted()
            if direction > 0 {
                within = sorted.last(where: { $0 > current + tolerance && $0 <= target + tolerance })
                neighbour = sorted.first(where: { $0 > current + tolerance })
            } else {
                within = sorted.first(where: { $0 < current - tolerance && $0 >= target - tolerance })
                neighbour = sorted.last(where: { $0 < current - tolerance })
            }
        }

        if let within { return clean(within) }
        guard let neighbour, neighbour > 0,
              abs(estimate - current) >= abs(neighbour - current) - tolerance
        else { return nil }
        return clean(neighbour)
    }

    /// Removes binary noise such as 0.9500000000000001.
    private static func clean(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    // MARK: Lows

    /// The moments at which a low began after `after`: a run of readings below the threshold, or
    /// a single severe one. Lows less than an hour apart count as one.
    static func lowEvents(
        _ glucose: [BasalTestGlucose],
        after: Date,
        limits: AutoSettingsLimits = AutoSettingsLimits()
    ) -> [Date] {
        var events: [Date] = []
        var runStart: Date?
        var runLength = 0
        var runCounted = false

        func add(_ date: Date) {
            if let last = events.last, date.timeIntervalSince(last) < 3600 { return }
            events.append(date)
        }

        for reading in glucose.sorted(by: { $0.date < $1.date }) where reading.date > after {
            guard reading.value < limits.lowThreshold else {
                runStart = nil
                runLength = 0
                runCounted = false
                continue
            }
            if runStart == nil { runStart = reading.date }
            runLength += 1

            let isSevere = reading.value < limits.severeLowThreshold
            if !runCounted, isSevere || runLength >= limits.lowRunLength {
                add(runStart ?? reading.date)
                runCounted = true
            }
        }
        return events
    }
}
