import Foundation

// MARK: - Settings and state

enum AutoSettingsMode: String, JSON, CaseIterable {
    case off
    /// Estimate and show, change nothing.
    case shadow
    /// Estimate and apply within the limits.
    case automatic
}

struct AutoSettingsSettings: JSON, Equatable {
    var mode: AutoSettingsMode = .off
    var adaptBasal: Bool = true
    var adaptSensitivity: Bool = true
    var adaptCarbRatio: Bool = true
    var adaptSportRecovery: Bool = true
    /// Hours after a sport profile during which glucose does not count for the base settings.
    var sportAfterEffectHours: Int = 12
    var notify: Bool = true
}

/// What the learner thinks about one value after its last run.
struct AutoSettingsProposal: JSON, Equatable, Identifiable {
    var key: String
    var scopeName: String
    var kind: AutoSettingKind
    var blockStartMinute: Int
    var current: Double
    var estimate: Double?
    var proposed: Double?
    var sampleCount: Int
    var dayCount: Int
    var verdict: AutoSettingsVerdict

    var id: String { key }
}

enum AutoSettingsChangeReason: String, JSON {
    case learned
    case revertedAfterLow
    case undone
}

/// One change of a value, proposed by the engine and, once applied, kept in the log.
struct AutoSettingsChange: JSON, Equatable, Identifiable {
    var id: String
    var date: Date
    var key: String
    var scope: String
    var scopeName: String
    var kind: AutoSettingKind
    var blockStartMinute: Int
    var oldValue: Double
    var newValue: Double
    var reason: AutoSettingsChangeReason
    /// Set on a learned change that was taken back later.
    var revertedAt: Date?
}

/// A phase of a sport profile as it actually ran.
struct AutoSettingsSportSpan: JSON, Equatable {
    var profileID: String
    var phaseID: String
    var start: Date
    var end: Date?
}

/// A stretch of time during which one therapy profile was active.
struct AutoSettingsProfileSpan: JSON, Equatable {
    var profileID: String
    var start: Date
    var end: Date?
}

struct AutoSettingsState: JSON, Equatable {
    /// The baseline of every value; changes stay within a band around it.
    var anchors: [String: Double] = [:]
    /// The values as the learner last saw them. A difference means someone edited them by hand.
    var lastKnown: [String: Double] = [:]
    var lastChangeAt: [String: Date] = [:]
    var blockedUntil: [String: Date] = [:]
    /// Until then no step towards more insulin is taken in the base settings.
    var frozenUntil: Date?
    var sportFrozenUntil: Date?
    var lastLowCheck: Date?
    var lastRun: Date?
    var proposals: [AutoSettingsProposal] = []
    var history: [AutoSettingsChange] = []
    var sportSpans: [AutoSettingsSportSpan] = []
    var profileSpans: [AutoSettingsProfileSpan] = []
}

// MARK: - Engine input and output

struct AutoSettingValue: Equatable {
    let scope: String
    let scopeName: String
    let kind: AutoSettingKind
    let blockStartMinute: Int
    let value: Double

    var key: String { AutoSettingsEngine.key(scope: scope, kind: kind, blockStartMinute: blockStartMinute) }
}

struct AutoSettingsContext {
    var now: Date
    var calendar: Calendar
    var settings: AutoSettingsSettings
    var state: AutoSettingsState
    /// Glucose, carbs, insulin and adjustments of the look-back period.
    var input: BasalTestInput
    var therapy: TherapySettingsSnapshot
    var activeProfileID: String
    var activeProfileName: String
    var sportProfiles: [SportProfile] = []
    var supportedBasalRates: [Double]?
    var maxBasal: Double?
    var insulinModel = InsulinActionModel()
    var dynamicISFEnabled: Bool = false
    var limits = AutoSettingsLimits()
    var basalConfig = AutoSettingsEngine.fastingConfig
    var sensitivityConfig = SensitivityConfig()
}

struct AutoSettingsOutcome {
    /// The state after the run, without the changes below. Each change is added with
    /// `AutoSettingsEngine.record` once it has really been applied.
    var state: AutoSettingsState
    /// Changes to apply now. Empty in shadow mode.
    var changes: [AutoSettingsChange]
}

// MARK: - Engine

/// The daily run of the settings learner: turns history into estimates, estimates into bounded
/// steps, and keeps the bookkeeping that makes those steps safe. Pure: no storage, no clock.
enum AutoSettingsEngine {
    static let historyLimit = 200

    /// How the learner picks fasting windows. Stricter than the basal check about glucose that is
    /// still moving: the drift is converted with the profile's ISF, so while the ISF is off, a
    /// moving window carries that error into the basal estimate. Over two weeks there are enough
    /// level windows to afford leaving the others out.
    static let fastingConfig: BasalTestConfig = {
        var config = BasalTestConfig()
        config.maxAbsSlopePerHour = 15
        return config
    }()
    static let spanRetentionDays: Double = 45
    private static let tolerance = 0.000_5

    static let sensitivityRange: ClosedRange<Double> = 9 ... 540
    static let carbRatioRange: ClosedRange<Double> = 1 ... 50
    static let sportPercentageRange: ClosedRange<Double> = 10 ... 100

    // MARK: Keys

    static func therapyScope(_ profileID: String) -> String { "therapy:" + profileID }

    static func sportScope(profileID: String, phaseID: String) -> String { "sport:" + profileID + ":" + phaseID }

    static func key(scope: String, kind: AutoSettingKind, blockStartMinute: Int) -> String {
        "\(scope)|\(kind.rawValue)|\(blockStartMinute)"
    }

    // MARK: Values

    static func therapyValues(
        _ settings: TherapySettingsSnapshot,
        profileID: String,
        profileName: String
    ) -> [AutoSettingValue] {
        let scope = therapyScope(profileID)
        func value(_ kind: AutoSettingKind, _ minute: Int, _ value: Decimal) -> AutoSettingValue {
            AutoSettingValue(scope: scope, scopeName: profileName, kind: kind, blockStartMinute: minute, value: Double(value))
        }
        return settings.basal.map { value(.basal, $0.minutes, $0.rate) }
            + settings.sensitivities.sensitivities.map { value(.sensitivity, $0.offset, $0.sensitivity) }
            + settings.carbRatios.schedule.map { value(.carbRatio, $0.offset, $0.ratio) }
    }

    static func sportValues(_ profiles: [SportProfile]) -> [AutoSettingValue] {
        profiles.flatMap { profile in
            profile.phases.filter { $0.kind == .recovery }.map { phase in
                AutoSettingValue(
                    scope: sportScope(profileID: profile.id, phaseID: phase.id),
                    scopeName: profile.name,
                    kind: .sportRecovery,
                    blockStartMinute: 0,
                    value: phase.percentage
                )
            }
        }
    }

    /// The therapy settings with one change written in. Returns `nil` when the change does not
    /// belong to these settings.
    static func applying(
        _ change: AutoSettingsChange,
        to settings: TherapySettingsSnapshot,
        profileID: String
    ) -> TherapySettingsSnapshot? {
        guard change.scope == therapyScope(profileID) else { return nil }
        var result = settings
        var found = false

        switch change.kind {
        case .basal:
            guard let rate = decimal(change.newValue, scale: 3) else { return nil }
            result.basal = settings.basal.map { entry in
                guard entry.minutes == change.blockStartMinute else { return entry }
                found = true
                return BasalProfileEntry(start: entry.start, minutes: entry.minutes, rate: rate)
            }
        case .sensitivity:
            guard let sensitivity = decimal(change.newValue, scale: 0) else { return nil }
            result.sensitivities.sensitivities = settings.sensitivities.sensitivities.map { entry in
                guard entry.offset == change.blockStartMinute else { return entry }
                found = true
                return InsulinSensitivityEntry(sensitivity: sensitivity, offset: entry.offset, start: entry.start)
            }
        case .carbRatio:
            guard let ratio = decimal(change.newValue, scale: 1) else { return nil }
            let schedule = settings.carbRatios.schedule.map { entry -> CarbRatioEntry in
                guard entry.offset == change.blockStartMinute else { return entry }
                found = true
                return CarbRatioEntry(start: entry.start, offset: entry.offset, ratio: ratio)
            }
            result.carbRatios = CarbRatios(units: settings.carbRatios.units, schedule: schedule)
        case .sportRecovery:
            return nil
        }
        return found ? result : nil
    }

    /// The sport profile a change belongs to, with the change written in.
    static func applying(_ change: AutoSettingsChange, to profiles: [SportProfile]) -> SportProfile? {
        guard change.kind == .sportRecovery else { return nil }
        for profile in profiles {
            guard let index = profile.phases.firstIndex(where: {
                sportScope(profileID: profile.id, phaseID: $0.id) == change.scope
            }) else { continue }
            var changed = profile
            changed.phases[index].percentage = min(
                max(change.newValue.rounded(), sportPercentageRange.lowerBound),
                sportPercentageRange.upperBound
            )
            return changed
        }
        return nil
    }

    private static func decimal(_ value: Double, scale: Int) -> Decimal? {
        Decimal(string: String(format: "%.\(scale)f", locale: Locale(identifier: "en_US_POSIX"), value))
    }

    // MARK: Run

    static func run(_ context: AutoSettingsContext) -> AutoSettingsOutcome {
        var state = context.state
        guard context.settings.mode != .off else { return AutoSettingsOutcome(state: state, changes: []) }

        let now = context.now
        let calendar = context.calendar
        let limits = context.limits
        let isAutomatic = context.settings.mode == .automatic
        let scope = therapyScope(context.activeProfileID)

        // The schedules in effect now are what every estimate is compared with.
        var input = context.input
        input.basalSchedule = context.therapy.basal.map {
            BasalTestScheduleEntry(startMinute: $0.minutes, value: Double($0.rate))
        }
        input.sensitivitySchedule = context.therapy.sensitivities.sensitivities.map {
            BasalTestScheduleEntry(startMinute: $0.offset, value: Double($0.sensitivity))
        }
        input.carbRatioSchedule = context.therapy.carbRatios.schedule.map {
            BasalTestScheduleEntry(startMinute: $0.offset, value: Double($0.ratio))
        }

        let baseValues = therapyValues(
            context.therapy,
            profileID: context.activeProfileID,
            profileName: context.activeProfileName
        )
        let recoveryValues = context.settings.adaptSportRecovery ? sportValues(context.sportProfiles) : []
        reconcile(&state, values: baseValues, scopePrefix: scope + "|", now: now)
        if context.settings.adaptSportRecovery {
            reconcile(&state, values: recoveryValues, scopePrefix: "sport:", now: now)
        }
        let currentValues = Dictionary(
            (baseValues + recoveryValues).map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )

        // Time that does not count for the base settings.
        let afterEffect = Double(max(context.settings.sportAfterEffectHours, 0)) * 3600
        let sportAffected = BasalTestEvaluator.merged(
            state.sportSpans.map {
                BasalTestSpan(start: $0.start, end: ($0.end ?? now).addingTimeInterval(afterEffect))
            }
        )
        let otherProfiles = state.profileSpans
            .filter { $0.profileID != context.activeProfileID }
            .map { BasalTestSpan(start: $0.start, end: $0.end ?? now) }

        // Lows since the last run pause steps towards more insulin and take the latest one back.
        var changes: [AutoSettingsChange] = []
        let lows = AutoSettingsPolicy.lowEvents(
            input.glucose,
            after: state.lastLowCheck ?? now.addingTimeInterval(-86400),
            limits: limits
        )
        state.lastLowCheck = now
        let sportLows = lows.filter { low in sportAffected.contains { $0.start <= low && low <= $0.end } }
        let baseLows = lows.filter { !sportLows.contains($0) }

        if let low = baseLows.last {
            state.frozenUntil = later(state.frozenUntil, low.addingTimeInterval(limits.freezeDays * 86400))
            if isAutomatic, let revert = revertChange(
                after: low, sport: false, scope: scope, state: state, currentValues: currentValues, now: now, limits: limits
            ) {
                changes.append(revert)
            }
        }
        if let low = sportLows.last {
            state.sportFrozenUntil = later(state.sportFrozenUntil, low.addingTimeInterval(limits.freezeDays * 86400))
            if isAutomatic, let revert = revertChange(
                after: low, sport: true, scope: scope, state: state, currentValues: currentValues, now: now, limits: limits
            ) {
                changes.append(revert)
            }
        }
        let revertedKeys = Set(changes.map(\.key))

        // Estimates for the base settings.
        var baseInput = input
        baseInput.adjustments += sportAffected + otherProfiles

        var samples: [String: [SettingSample]] = [:]
        func collect(_ kind: AutoSettingKind, _ list: [SettingSample]) {
            for sample in list {
                samples[key(scope: scope, kind: kind, blockStartMinute: sample.blockStartMinute), default: []].append(sample)
            }
        }

        // All insulin relative to the scheduled basal rate, for the whole look-back period.
        var doses: [InsulinDose] = []
        if let firstGlucose = input.glucose.map(\.date).min() {
            doses = InsulinAccounting.netDoses(
                input,
                from: firstGlucose.addingTimeInterval(-max(context.insulinModel.durationMinutes, 180) * 60),
                to: now,
                calendar: calendar
            )
        }
        func scheduledRate(_ window: BasalTestWindow) -> Double? {
            input.basalSchedule.first { $0.startMinute == window.blockStartMinute }?.value
        }

        let sortedGlucose = input.glucose.sorted { $0.date < $1.date }
        func needSample(_ window: BasalTestWindow) -> (need: Double, scheduled: Double)? {
            guard let scheduled = scheduledRate(window), scheduled > 0,
                  BasalNeedEstimator.isSmooth(sortedGlucose, from: window.start, to: window.end),
                  let need = BasalNeedEstimator.need(
                      in: window, scheduledRate: scheduled, doses: doses, model: context.insulinModel
                  )
            else { return nil }
            return (need, scheduled)
        }

        // The basal need is estimated even when basal is not adapted: sensitivity and carb ratio
        // have to know how much insulin the basal need used up.
        let basalSamples: [SettingSample] = BasalTestEvaluator
            .windows(baseInput, config: context.basalConfig, calendar: calendar)
            .compactMap { window in
                needSample(window).map {
                    SettingSample(date: window.start, blockStartMinute: window.blockStartMinute, value: $0.need)
                }
            }
        if context.settings.adaptBasal {
            collect(.basal, basalSamples)
        }

        var needOffsets: [Int: Double] = [:]
        for entry in input.basalSchedule where entry.value > 0 {
            let block = basalSamples.filter { $0.blockStartMinute == entry.startMinute }
            let days = Set(block.map { calendar.startOfDay(for: $0.date) }).count
            guard block.count >= limits.minSamplesBasal, days >= limits.minDays else { continue }
            let offset = AutoSettingsPolicy.median(block.map(\.value).sorted()) - entry.value
            // An estimate far from the schedule is more likely bad data than a real need.
            needOffsets[entry.startMinute] = min(max(offset, -0.3 * entry.value), 0.3 * entry.value)
        }
        let basalOffset: (Date) -> Double = { date in
            needOffsets[SensitivityEstimator.blockStart(at: date, schedule: input.basalSchedule, calendar: calendar)] ?? 0
        }

        let learnsSensitivity = context.settings.adaptSensitivity && !context.dynamicISFEnabled
        if !doses.isEmpty {
            if learnsSensitivity {
                collect(.sensitivity, SensitivityEstimator.sensitivitySamples(
                    baseInput,
                    doses: doses,
                    model: context.insulinModel,
                    config: context.sensitivityConfig,
                    base: context.basalConfig,
                    calendar: calendar,
                    basalOffset: basalOffset
                ))
            }
            if context.settings.adaptCarbRatio {
                collect(.carbRatio, SensitivityEstimator.carbRatioSamples(
                    baseInput,
                    doses: doses,
                    model: context.insulinModel,
                    config: context.sensitivityConfig,
                    base: context.basalConfig,
                    calendar: calendar,
                    basalOffset: basalOffset
                ))
            }
        }

        // Decisions. Only one kind of base setting moves at a time, basal first, so that the
        // effect of a step can be seen before the next kind is touched.
        let isFrozen = (state.frozenUntil ?? .distantPast) > now
        let recentKind = state.history.last(where: {
            $0.scope == scope && $0.reason == .learned && $0.revertedAt == nil
                && now.timeIntervalSince($0.date) < limits.daysBetweenSteps * 86400
        })?.kind
        var movingKind: AutoSettingKind?
        var proposals: [AutoSettingsProposal] = []

        let rates = (context.supportedBasalRates ?? []).filter { $0 > 0 }
        let basalGrid: AutoSettingsGrid = rates.isEmpty ? .step(0.05) : .values(rates)
        let highestBasal = (context.maxBasal ?? 0) > 0 ? context.maxBasal! : 10
        let basalRange = (rates.min() ?? 0.05) ... max(highestBasal, rates.min() ?? 0.05)

        func isEnabled(_ kind: AutoSettingKind) -> Bool {
            switch kind {
            case .basal: return context.settings.adaptBasal
            case .sensitivity: return context.settings.adaptSensitivity
            case .carbRatio: return context.settings.adaptCarbRatio
            case .sportRecovery: return context.settings.adaptSportRecovery
            }
        }

        func proposal(_ value: AutoSettingValue, _ decision: AutoSettingsDecision) -> AutoSettingsProposal {
            AutoSettingsProposal(
                key: value.key,
                scopeName: value.scopeName,
                kind: value.kind,
                blockStartMinute: value.blockStartMinute,
                current: value.value,
                estimate: decision.estimate,
                proposed: decision.proposed,
                sampleCount: decision.sampleCount,
                dayCount: decision.dayCount,
                verdict: decision.verdict
            )
        }

        func change(_ value: AutoSettingValue, to newValue: Double) -> AutoSettingsChange {
            AutoSettingsChange(
                id: "\(value.key)@\(Int(now.timeIntervalSince1970))",
                date: now,
                key: value.key,
                scope: value.scope,
                scopeName: value.scopeName,
                kind: value.kind,
                blockStartMinute: value.blockStartMinute,
                oldValue: value.value,
                newValue: newValue,
                reason: .learned,
                revertedAt: nil
            )
        }

        for kind in [AutoSettingKind.basal, .sensitivity, .carbRatio] where isEnabled(kind) {
            for value in baseValues where value.kind == kind {
                if kind == .sensitivity, context.dynamicISFEnabled {
                    proposals.append(proposal(value, AutoSettingsDecision(
                        verdict: .notAdapted, estimate: nil, proposed: nil, sampleCount: 0, dayCount: 0
                    )))
                    continue
                }

                let grid: AutoSettingsGrid
                let range: ClosedRange<Double>
                switch kind {
                case .basal:
                    grid = basalGrid
                    range = basalRange
                case .sensitivity:
                    grid = .step(1)
                    range = sensitivityRange
                default:
                    grid = .step(0.1)
                    range = carbRatioRange
                }

                var decision = AutoSettingsPolicy.decide(
                    kind: kind,
                    current: value.value,
                    anchor: state.anchors[value.key] ?? value.value,
                    samples: samples[value.key] ?? [],
                    lastChange: state.lastChangeAt[value.key],
                    blockedUntil: state.blockedUntil[value.key],
                    moreInsulinFrozen: isFrozen,
                    grid: grid,
                    hardRange: range,
                    now: now,
                    calendar: calendar,
                    limits: limits
                )

                if decision.verdict == .change, let proposed = decision.proposed {
                    if revertedKeys.contains(value.key) {
                        decision.verdict = .waiting
                    } else if (recentKind ?? kind) != kind || (movingKind ?? kind) != kind {
                        decision.verdict = .otherKindFirst
                    } else {
                        movingKind = kind
                        if isAutomatic {
                            changes.append(change(value, to: proposed))
                        }
                    }
                }
                proposals.append(proposal(value, decision))
            }
        }

        // The recovery phase of each sport profile, from the time it actually ran.
        if context.settings.adaptSportRecovery {
            let isSportFrozen = (state.sportFrozenUntil ?? .distantPast) > now
            let dates = input.glucose.map(\.date)

            for value in recoveryValues {
                let spans = BasalTestEvaluator.merged(
                    state.sportSpans
                        .filter { sportScope(profileID: $0.profileID, phaseID: $0.phaseID) == value.scope }
                        .map { BasalTestSpan(start: $0.start, end: $0.end ?? now) }
                )

                var recoverySamples: [SettingSample] = []
                if !spans.isEmpty, let first = dates.min(), let last = dates.max(), first < last {
                    var recoveryInput = input
                    // Everything outside the phase is excluded, the phase itself is not.
                    recoveryInput.adjustments = BasalTestEvaluator.subtract(
                        spans,
                        from: BasalTestSpan(start: first, end: last)
                    ) + otherProfiles

                    let windows = BasalTestEvaluator.windows(recoveryInput, config: context.basalConfig, calendar: calendar)
                    for window in windows {
                        guard let sample = needSample(window) else { continue }
                        // Relative to what the base settings need at that time of day, so that a
                        // basal rate that is off does not end up in the sport percentage.
                        let baseNeed = sample.scheduled + (needOffsets[window.blockStartMinute] ?? 0)
                        guard baseNeed > 0 else { continue }
                        recoverySamples.append(
                            SettingSample(date: window.start, blockStartMinute: 0, value: sample.need / baseNeed * 100)
                        )
                    }
                }

                var decision = AutoSettingsPolicy.decide(
                    kind: .sportRecovery,
                    current: value.value,
                    anchor: state.anchors[value.key] ?? value.value,
                    samples: recoverySamples,
                    lastChange: state.lastChangeAt[value.key],
                    blockedUntil: state.blockedUntil[value.key],
                    moreInsulinFrozen: isSportFrozen,
                    grid: .step(1),
                    hardRange: sportPercentageRange,
                    now: now,
                    calendar: calendar,
                    limits: limits
                )
                if decision.verdict == .change, let proposed = decision.proposed {
                    if revertedKeys.contains(value.key) {
                        decision.verdict = .waiting
                    } else if isAutomatic {
                        changes.append(change(value, to: proposed))
                    }
                }
                proposals.append(proposal(value, decision))
            }
        }

        state.proposals = proposals
        state.lastRun = now
        prune(&state, now: now)
        return AutoSettingsOutcome(state: state, changes: changes)
    }

    // MARK: Bookkeeping

    /// Notices manual edits and new values. A manual edit becomes the new baseline and makes the
    /// learner wait, as if it had taken a step itself.
    static func reconcile(_ state: inout AutoSettingsState, values: [AutoSettingValue], scopePrefix: String, now: Date) {
        let keys = Set(values.map(\.key))
        for value in values {
            if let known = state.lastKnown[value.key], abs(known - value.value) > tolerance {
                state.anchors[value.key] = value.value
                state.lastChangeAt[value.key] = now
            }
            if state.anchors[value.key] == nil {
                state.anchors[value.key] = value.value
            }
            state.lastKnown[value.key] = value.value
        }
        // Values that no longer exist, for example a time block that was removed.
        for key in state.lastKnown.keys where key.hasPrefix(scopePrefix) && !keys.contains(key) {
            state.anchors[key] = nil
            state.lastKnown[key] = nil
            state.lastChangeAt[key] = nil
            state.blockedUntil[key] = nil
        }
    }

    /// Makes the current values the baseline, so the band is centred on them again.
    static func confirmBaseline(_ state: inout AutoSettingsState, values: [AutoSettingValue]) {
        for value in values {
            state.anchors[value.key] = value.value
            state.lastKnown[value.key] = value.value
        }
    }

    /// Adds an applied change to the log and updates what the learner knows about the value.
    static func record(
        _ change: AutoSettingsChange,
        in state: inout AutoSettingsState,
        limits: AutoSettingsLimits = AutoSettingsLimits()
    ) {
        state.lastKnown[change.key] = change.newValue
        state.lastChangeAt[change.key] = change.date

        if change.reason != .learned {
            if let index = state.history.lastIndex(where: {
                $0.key == change.key && $0.reason == .learned && $0.revertedAt == nil
                    && abs($0.newValue - change.oldValue) <= tolerance
            }) {
                state.history[index].revertedAt = change.date
            }
        }
        if change.reason == .undone {
            state.blockedUntil[change.key] = change.date.addingTimeInterval(limits.undoBlockDays * 86400)
        }

        state.history.append(change)
        if state.history.count > historyLimit {
            state.history.removeFirst(state.history.count - historyLimit)
        }
    }

    /// The change that takes a learned change back, if the value is still what the learner set.
    static func undoChange(
        for changeID: String,
        state: AutoSettingsState,
        currentValue: Double?,
        now: Date
    ) -> AutoSettingsChange? {
        guard let original = state.history.first(where: { $0.id == changeID }),
              original.reason == .learned, original.revertedAt == nil,
              let currentValue, abs(currentValue - original.newValue) <= tolerance
        else { return nil }
        return reversal(of: original, reason: .undone, now: now)
    }

    private static func revertChange(
        after low: Date,
        sport: Bool,
        scope: String,
        state: AutoSettingsState,
        currentValues: [String: Double],
        now: Date,
        limits: AutoSettingsLimits
    ) -> AutoSettingsChange? {
        guard let original = state.history.last(where: { change in
            change.reason == .learned && change.revertedAt == nil
                && (change.kind == .sportRecovery) == sport
                && (sport || change.scope == scope)
                && change.date <= low
                && low.timeIntervalSince(change.date) <= limits.revertWindowDays * 86400
                && change.kind.isMoreInsulin(from: change.oldValue, to: change.newValue)
        }),
            let current = currentValues[original.key], abs(current - original.newValue) <= tolerance
        else { return nil }
        return reversal(of: original, reason: .revertedAfterLow, now: now)
    }

    private static func reversal(
        of original: AutoSettingsChange,
        reason: AutoSettingsChangeReason,
        now: Date
    ) -> AutoSettingsChange {
        AutoSettingsChange(
            id: "\(original.key)@\(Int(now.timeIntervalSince1970))-\(reason.rawValue)",
            date: now,
            key: original.key,
            scope: original.scope,
            scopeName: original.scopeName,
            kind: original.kind,
            blockStartMinute: original.blockStartMinute,
            oldValue: original.newValue,
            newValue: original.oldValue,
            reason: reason,
            revertedAt: nil
        )
    }

    private static func later(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private static func prune(_ state: inout AutoSettingsState, now: Date) {
        let cutoff = now.addingTimeInterval(-spanRetentionDays * 86400)
        state.sportSpans.removeAll { ($0.end ?? now) < cutoff }
        state.profileSpans.removeAll { ($0.end ?? now) < cutoff }
        state.blockedUntil = state.blockedUntil.filter { $0.value > now }
    }

    // MARK: Spans

    /// Keeps the log of sport phases in step with the running sport profile.
    /// Returns `true` when the log changed.
    @discardableResult static func syncSportSpans(
        _ state: inout AutoSettingsState,
        run: SportProfileRun?,
        profiles: [SportProfile],
        now: Date
    ) -> Bool {
        var current: AutoSettingsSportSpan?
        if let run,
           let profile = profiles.first(where: { $0.id == run.profileID }),
           profile.phases.indices.contains(run.phaseIndex)
        {
            current = AutoSettingsSportSpan(
                profileID: profile.id,
                phaseID: profile.phases[run.phaseIndex].id,
                start: run.phaseStartedAt,
                end: nil
            )
        }

        if let open = state.sportSpans.last, open.end == nil {
            if let current, current.profileID == open.profileID, current.phaseID == open.phaseID,
               abs(current.start.timeIntervalSince(open.start)) < 1
            {
                return false
            }
            let end = current.map { max($0.start, open.start) } ?? now
            state.sportSpans[state.sportSpans.count - 1].end = max(end, open.start)
        } else if current == nil {
            return false
        }

        if let current {
            state.sportSpans.append(current)
        }
        return true
    }

    /// Keeps the log of active therapy profiles. Before the first entry nothing is known, so the
    /// first profile is assumed to have been active throughout the look-back period.
    @discardableResult static func syncProfileSpans(
        _ state: inout AutoSettingsState,
        activeProfileID: String,
        now: Date
    ) -> Bool {
        if let open = state.profileSpans.last, open.end == nil {
            if open.profileID == activeProfileID { return false }
            state.profileSpans[state.profileSpans.count - 1].end = now
            state.profileSpans.append(AutoSettingsProfileSpan(profileID: activeProfileID, start: now, end: nil))
            return true
        }
        let start = state.profileSpans.isEmpty ? now.addingTimeInterval(-spanRetentionDays * 86400) : now
        state.profileSpans.append(AutoSettingsProfileSpan(profileID: activeProfileID, start: start, end: nil))
        return true
    }
}
