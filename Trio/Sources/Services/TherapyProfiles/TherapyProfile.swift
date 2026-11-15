import Foundation

// MARK: - Models

/// One complete set of therapy settings: what the four settings files hold together.
struct TherapySettingsSnapshot: JSON {
    var basal: [BasalProfileEntry]
    var sensitivities: InsulinSensitivities
    var carbRatios: CarbRatios
    var targets: BGTargets
}

struct TherapyProfile: JSON, Identifiable {
    var id: String
    var name: String
    var settings: TherapySettingsSnapshot
    var updatedAt: Date
}

/// The profile library as stored on disk. The settings files stay the source of truth for the
/// active profile; its entry here is refreshed from them whenever another profile is activated.
struct TherapyProfileLibrary: JSON {
    var activeProfileID: String?
    var profiles: [TherapyProfile]
}

enum TherapySettingCategory: String, CaseIterable {
    case basal
    case sensitivity
    case carbRatio
    case target
}

/// One changed value between two snapshots, at a time of day.
struct TherapyProfileDifference: Identifiable, Equatable {
    let category: TherapySettingCategory
    /// Minutes after midnight.
    let minutes: Int
    let oldValue: Decimal?
    let newValue: Decimal?

    var id: String { "\(category.rawValue)-\(minutes)" }
}

enum TherapyProfileProblem: Equatable {
    case emptySchedule(TherapySettingCategory)
    case scheduleDoesNotStartAtMidnight(TherapySettingCategory)
    case scheduleNotAscending(TherapySettingCategory)
    case valueOutOfRange(TherapySettingCategory, minutes: Int, value: Decimal)
    case basalRateNotSupportedByPump(minutes: Int, value: Decimal)
    case basalRateAboveMaxBasal(minutes: Int, value: Decimal)
}

// MARK: - Logic

/// Pure rules for therapy profiles: scaling, validation and comparison. No storage, no pump.
enum TherapyProfileLogic {
    /// Same limits as the editors use for their pickers.
    static let sensitivityRange: ClosedRange<Decimal> = 9 ... 540
    static let carbRatioRange: ClosedRange<Decimal> = 1 ... 50
    static let targetRange: ClosedRange<Decimal> = 72 ... 180
    static let percentageRange: ClosedRange<Decimal> = 50 ... 150
    private static let rateTolerance: Decimal = 0.001

    // MARK: Scaling

    /// Returns a copy that delivers `percentage` percent of the insulin of the original:
    /// basal is multiplied, ISF and carb ratio are divided, targets stay as they are.
    static func scaled(
        _ settings: TherapySettingsSnapshot,
        percentage: Decimal,
        supportedBasalRates: [Decimal]?
    ) -> TherapySettingsSnapshot {
        let clamped = min(max(percentage, percentageRange.lowerBound), percentageRange.upperBound)
        guard clamped != 100 else { return settings }
        let factor = clamped / 100

        let basal = settings.basal.map { entry in
            BasalProfileEntry(
                start: entry.start,
                minutes: entry.minutes,
                rate: roundedBasalRate(entry.rate * factor, supportedBasalRates: supportedBasalRates)
            )
        }

        let sensitivities = settings.sensitivities.sensitivities.map { entry in
            InsulinSensitivityEntry(
                sensitivity: clamp(rounded(entry.sensitivity / factor, scale: 0, roundingMode: .plain), to: sensitivityRange),
                offset: entry.offset,
                start: entry.start
            )
        }

        let ratios = settings.carbRatios.schedule.map { entry in
            CarbRatioEntry(
                start: entry.start,
                offset: entry.offset,
                ratio: clamp(rounded(entry.ratio / factor, scale: 1, roundingMode: .plain), to: carbRatioRange)
            )
        }

        return TherapySettingsSnapshot(
            basal: basal,
            sensitivities: InsulinSensitivities(
                units: settings.sensitivities.units,
                userPreferredUnits: settings.sensitivities.userPreferredUnits,
                sensitivities: sensitivities
            ),
            carbRatios: CarbRatios(units: settings.carbRatios.units, schedule: ratios),
            targets: settings.targets
        )
    }

    /// Rounds to the nearest rate the pump can deliver. Without a pump, rounds to 0.05 U/h, which
    /// is the step the basal editor falls back to. Never returns zero.
    static func roundedBasalRate(_ rate: Decimal, supportedBasalRates: [Decimal]?) -> Decimal {
        let candidates = (supportedBasalRates ?? []).filter { $0 > 0 }
        if let nearest = candidates.min(by: { abs($0 - rate) < abs($1 - rate) }) {
            return rounded(nearest, scale: 3, roundingMode: .plain)
        }
        let steps = rounded(rate / Decimal(string: "0.05")!, scale: 0, roundingMode: .plain)
        return max(steps, 1) * Decimal(string: "0.05")!
    }

    static func isSupported(_ rate: Decimal, supportedBasalRates: [Decimal]) -> Bool {
        supportedBasalRates.contains { abs($0 - rate) <= rateTolerance }
    }

    // MARK: Validation

    static func validate(
        _ settings: TherapySettingsSnapshot,
        supportedBasalRates: [Decimal]?,
        maxBasal: Decimal?
    ) -> [TherapyProfileProblem] {
        var problems: [TherapyProfileProblem] = []

        problems += scheduleProblems(.basal, minutes: settings.basal.map(\.minutes))
        for entry in settings.basal {
            if entry.rate <= 0 {
                problems.append(.valueOutOfRange(.basal, minutes: entry.minutes, value: entry.rate))
            } else if let supportedBasalRates, !supportedBasalRates.isEmpty,
                      !isSupported(entry.rate, supportedBasalRates: supportedBasalRates)
            {
                problems.append(.basalRateNotSupportedByPump(minutes: entry.minutes, value: entry.rate))
            } else if let maxBasal, maxBasal > 0, entry.rate > maxBasal {
                problems.append(.basalRateAboveMaxBasal(minutes: entry.minutes, value: entry.rate))
            }
        }

        problems += scheduleProblems(.sensitivity, minutes: settings.sensitivities.sensitivities.map(\.offset))
        for entry in settings.sensitivities.sensitivities where !sensitivityRange.contains(entry.sensitivity) {
            problems.append(.valueOutOfRange(.sensitivity, minutes: entry.offset, value: entry.sensitivity))
        }

        problems += scheduleProblems(.carbRatio, minutes: settings.carbRatios.schedule.map(\.offset))
        for entry in settings.carbRatios.schedule where !carbRatioRange.contains(entry.ratio) {
            problems.append(.valueOutOfRange(.carbRatio, minutes: entry.offset, value: entry.ratio))
        }

        problems += scheduleProblems(.target, minutes: settings.targets.targets.map(\.offset))
        for entry in settings.targets.targets where !targetRange.contains(entry.low) {
            problems.append(.valueOutOfRange(.target, minutes: entry.offset, value: entry.low))
        }

        return problems
    }

    private static func scheduleProblems(_ category: TherapySettingCategory, minutes: [Int]) -> [TherapyProfileProblem] {
        guard let first = minutes.first else { return [.emptySchedule(category)] }
        var problems: [TherapyProfileProblem] = []
        if first != 0 {
            problems.append(.scheduleDoesNotStartAtMidnight(category))
        }
        let ascending = zip(minutes, minutes.dropFirst()).allSatisfy { $0 < $1 }
        if !ascending || (minutes.last ?? 0) >= 24 * 60 {
            problems.append(.scheduleNotAscending(category))
        }
        return problems
    }

    // MARK: Comparison

    /// Every time of day at which the two snapshots are in effect with different values.
    static func differences(
        from old: TherapySettingsSnapshot,
        to new: TherapySettingsSnapshot
    ) -> [TherapyProfileDifference] {
        var result: [TherapyProfileDifference] = []
        result += scheduleDifferences(
            .basal,
            old: old.basal.map { ($0.minutes, $0.rate) },
            new: new.basal.map { ($0.minutes, $0.rate) }
        )
        result += scheduleDifferences(
            .sensitivity,
            old: old.sensitivities.sensitivities.map { ($0.offset, $0.sensitivity) },
            new: new.sensitivities.sensitivities.map { ($0.offset, $0.sensitivity) }
        )
        result += scheduleDifferences(
            .carbRatio,
            old: old.carbRatios.schedule.map { ($0.offset, $0.ratio) },
            new: new.carbRatios.schedule.map { ($0.offset, $0.ratio) }
        )
        result += scheduleDifferences(
            .target,
            old: old.targets.targets.map { ($0.offset, $0.low) },
            new: new.targets.targets.map { ($0.offset, $0.low) }
        )
        return result
    }

    static func hasSameBasal(_ lhs: [BasalProfileEntry], _ rhs: [BasalProfileEntry]) -> Bool {
        scheduleDifferences(
            .basal,
            old: lhs.map { ($0.minutes, $0.rate) },
            new: rhs.map { ($0.minutes, $0.rate) }
        ).isEmpty
    }

    private static func scheduleDifferences(
        _ category: TherapySettingCategory,
        old: [(Int, Decimal)],
        new: [(Int, Decimal)]
    ) -> [TherapyProfileDifference] {
        let boundaries = Set(old.map { $0.0 } + new.map { $0.0 }).sorted()
        var result: [TherapyProfileDifference] = []
        for minutes in boundaries {
            let oldValue = value(at: minutes, in: old)
            let newValue = value(at: minutes, in: new)
            if !isSame(oldValue, newValue) {
                result.append(
                    TherapyProfileDifference(category: category, minutes: minutes, oldValue: oldValue, newValue: newValue)
                )
            }
        }
        return result
    }

    /// The value in effect at a time of day: the last entry that starts at or before it.
    private static func value(at minutes: Int, in schedule: [(Int, Decimal)]) -> Decimal? {
        schedule.last(where: { $0.0 <= minutes })?.1
    }

    private static func isSame(_ lhs: Decimal?, _ rhs: Decimal?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs - rhs) <= rateTolerance
        default:
            return false
        }
    }

    private static func clamp(_ value: Decimal, to range: ClosedRange<Decimal>) -> Decimal {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Helpers for display and editing

    /// Total basal insulin of a schedule over 24 hours.
    static func dailyBasal(_ basal: [BasalProfileEntry]) -> Decimal {
        var total: Decimal = 0
        for (index, entry) in basal.enumerated() {
            let end = index + 1 < basal.count ? basal[index + 1].minutes : 24 * 60
            total += Decimal(max(end - entry.minutes, 0)) / 60 * entry.rate
        }
        return total
    }

    static func timeString(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
