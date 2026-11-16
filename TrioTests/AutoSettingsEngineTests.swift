import Foundation
import Testing

@testable import Trio

// MARK: - Fixtures

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

/// Midnight UTC.
private let dayZero = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400))

private func decimal(_ value: Double) -> Decimal {
    Decimal(string: String(format: "%.3f", value))!
}

private func makeTherapy(basal: Double, sensitivity: Double, carbRatio: Double) -> TherapySettingsSnapshot {
    TherapySettingsSnapshot(
        basal: [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: decimal(basal))],
        sensitivities: InsulinSensitivities(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            sensitivities: [InsulinSensitivityEntry(sensitivity: decimal(sensitivity), offset: 0, start: "00:00:00")]
        ),
        carbRatios: CarbRatios(
            units: .grams,
            schedule: [CarbRatioEntry(start: "00:00:00", offset: 0, ratio: decimal(carbRatio))]
        ),
        targets: BGTargets(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            targets: [BGTargetEntry(low: 100, high: 100, start: "00:00:00", offset: 0)]
        )
    )
}

private let pumpRates: [Double] = (1 ... 200).map { Double($0) * 0.05 }
private let profileID = "standard"
private let scope = AutoSettingsEngine.therapyScope(profileID)

private func key(_ kind: AutoSettingKind) -> String {
    AutoSettingsEngine.key(scope: scope, kind: kind, blockStartMinute: 0)
}

private func makeContext(
    now: Date,
    mode: AutoSettingsMode = .automatic,
    state: AutoSettingsState = AutoSettingsState(),
    input: BasalTestInput = BasalTestInput(),
    therapy: TherapySettingsSnapshot = makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
) -> AutoSettingsContext {
    var settings = AutoSettingsSettings()
    settings.mode = mode
    var context = AutoSettingsContext(
        now: now,
        calendar: utc,
        settings: settings,
        state: state,
        input: input,
        therapy: therapy,
        activeProfileID: profileID,
        activeProfileName: "Standard"
    )
    context.supportedBasalRates = pumpRates
    context.maxBasal = 5
    return context
}

// MARK: - Simulation

/// A patient whose true needs are known, with a crude closed loop around them: a proportional
/// temp basal, meal boluses from the profile, and one correction a night. The learner sees only
/// what it would see in the app: glucose, carbs, boluses and temp basals.
private final class Simulation {
    struct Truth {
        var basal: Double
        var sensitivity: Double
        var carbRatio: Double
        /// Share of the basal need that remains during the nightly recovery phase.
        var recoveryFactor: Double = 1
    }

    let truth: Truth
    var therapy: TherapySettingsSnapshot
    var settings = AutoSettingsSettings()
    var limits = AutoSettingsLimits()
    var state = AutoSettingsState()
    var sportProfile: SportProfile?
    var withCorrections = true
    var meals: [(minute: Int, grams: Double)] = [(450, 45), (780, 55), (1140, 50)]

    private(set) var input = BasalTestInput()
    private(set) var applied: [AutoSettingsChange] = []
    private(set) var lastOutcome: AutoSettingsOutcome?
    private(set) var lowestGlucose = 400.0
    private(set) var now = dayZero

    /// What the learner thought after its last run, for failure messages.
    var summary: String {
        state.proposals.map { proposal in
            let estimate = proposal.estimate.map { String(format: "%.2f", $0) } ?? "-"
            return "\(proposal.kind.rawValue) \(proposal.current): \(proposal.verdict.rawValue), estimate \(estimate), n=\(proposal.sampleCount)"
        }.joined(separator: "; ") + "; lowest glucose \(Int(lowestGlucose))"
    }

    private let model = InsulinActionModel()
    private let fractions: [Double]
    private let remaining: [Double]
    /// All insulin per step, and the part of it above the scheduled basal rate.
    private var insulin: [Double]
    private var netInsulin: [Double]
    private var carbRise: [Double] = []
    /// Glucose rise the loop still expects from carbs, judged by the profile.
    private var expectedRise: [Double] = []
    private var glucose = 100.0
    private var step = 0

    init(truth: Truth, therapy: TherapySettingsSnapshot) {
        self.truth = truth
        self.therapy = therapy
        let model = self.model
        fractions = (0 ..< 72).map { model.remaining(after: Double($0) * 5) - model.remaining(after: Double($0 + 1) * 5) }
        remaining = (0 ..< 72).map { model.remaining(after: Double($0) * 5) }
        // The patient starts in balance.
        insulin = Array(repeating: truth.basal * 5 / 60, count: 72)
        netInsulin = Array(repeating: 0, count: 72)
        settings.mode = .automatic
        settings.sportAfterEffectHours = 0
    }

    var basal: Double { Double(therapy.basal[0].rate) }
    var sensitivity: Double { Double(therapy.sensitivities.sensitivities[0].sensitivity) }
    var carbRatio: Double { Double(therapy.carbRatios.schedule[0].ratio) }
    var recoveryPercentage: Double { sportProfile?.phases.first { $0.kind == .recovery }?.percentage ?? 100 }

    func run(days: Int) {
        for _ in 0 ..< days * 288 {
            advance()
        }
    }

    private func advance() {
        now = dayZero.addingTimeInterval(Double(step) * 300)
        let minute = (step * 5) % 1440

        input.glucose.append(BasalTestGlucose(date: now, value: glucose))
        lowestGlucose = min(lowestGlucose, glucose)

        if minute == 240 {
            learn()
        }

        // The recovery phase of the sport profile runs every night from 20:00 to 06:00.
        let isRecovering = sportProfile != nil && (minute >= 1200 || minute < 360)
        if let profile = sportProfile, let phase = profile.phases.first(where: { $0.kind == .recovery }) {
            if minute == 1200 {
                state.sportSpans.append(AutoSettingsSportSpan(profileID: profile.id, phaseID: phase.id, start: now, end: nil))
            } else if minute == 360, let last = state.sportSpans.indices.last, state.sportSpans[last].end == nil {
                state.sportSpans[last].end = now
            }
        }

        while carbRise.count < step + 38 {
            carbRise.append(0)
            expectedRise.append(0)
        }

        var bolus = 0.0
        let isMeal = meals.contains { $0.minute == minute }
        if let meal = meals.first(where: { $0.minute == minute }) {
            input.carbDates.append(now)
            input.carbs.append(BasalTestCarb(date: now, grams: meal.grams))
            bolus += meal.grams / carbRatio
            for offset in 1 ... 36 {
                carbRise[step + offset] += meal.grams * truth.sensitivity / truth.carbRatio / 36
                expectedRise[step + offset] += meal.grams * sensitivity / carbRatio / 36
            }
        }

        // Where the loop expects glucose to end up, judged by the profile: insulin on board
        // pulls down, carbs on board push up.
        var insulinOnBoard = 0.0
        for age in 0 ..< 72 {
            insulinOnBoard += netInsulin[netInsulin.count - 1 - age] * remaining[age]
        }
        let carbsOnBoard = expectedRise[(step + 1)...].reduce(0, +)
        let eventual = glucose - sensitivity * insulinOnBoard + carbsOnBoard
        // The meal bolus is not on board yet; it covers the carbs that are.
        let insulinRequired = (eventual - 100) / sensitivity - bolus

        // Meals and the nightly correction are bolused by hand, the rest is temp basal.
        let isCorrectionDay = withCorrections && (step / 288) % 2 == 0
        let isBolusTime = isMeal || (isCorrectionDay && minute == 185)
        if isBolusTime {
            bolus = max(0, bolus + insulinRequired)
        }
        if bolus > 0 {
            input.boluses.append(BasalTestBolus(date: now, units: bolus, isAutomatic: false))
        }

        let scheduled = basal * (isRecovering ? recoveryPercentage / 100 : 1)
        let rate = isBolusTime ? scheduled : min(max(scheduled + 2 * insulinRequired, 0), basal * 3)
        input.tempBasals.append(BasalTestTempBasal(start: now, durationMinutes: 5, rate: rate, isScheduledBasal: false))
        insulin.append(rate * 5 / 60 + bolus)
        // Like the loop, relative to the basal rate in effect, override included.
        netInsulin.append((rate - scheduled) * 5 / 60 + bolus)

        var absorbed = 0.0
        let latest = insulin.count - 1
        for age in 0 ..< 72 {
            absorbed += insulin[latest - age] * fractions[age]
        }

        let need = truth.basal * (isRecovering ? truth.recoveryFactor : 1)
        glucose += truth.sensitivity * (need * 5 / 60 - absorbed)
        if step < carbRise.count {
            glucose += carbRise[step]
        }
        // Something unannounced pushes glucose up every other night; the correction follows.
        if isCorrectionDay, minute == 180 {
            glucose += 70
        }
        glucose = max(glucose, 40)
        step += 1
    }

    private func learn() {
        let cutoff = now.addingTimeInterval(-14 * 86400)
        let eventCutoff = cutoff.addingTimeInterval(-86400)
        var recent = BasalTestInput()
        recent.glucose = input.glucose.filter { $0.date >= cutoff }
        recent.carbDates = input.carbDates.filter { $0 >= eventCutoff }
        recent.carbs = input.carbs.filter { $0.date >= eventCutoff }
        recent.boluses = input.boluses.filter { $0.date >= eventCutoff }
        recent.tempBasals = input.tempBasals.filter { $0.start >= eventCutoff }

        var context = makeContext(now: now, state: state, input: recent, therapy: therapy)
        context.settings = settings
        context.limits = limits
        context.sportProfiles = sportProfile.map { [$0] } ?? []

        let outcome = AutoSettingsEngine.run(context)
        state = outcome.state
        for change in outcome.changes {
            if let changed = AutoSettingsEngine.applying(change, to: therapy, profileID: profileID) {
                therapy = changed
            } else if let changed = AutoSettingsEngine.applying(change, to: context.sportProfiles) {
                sportProfile = changed
            } else {
                continue
            }
            AutoSettingsEngine.record(change, in: &state)
            applied.append(change)
        }
        lastOutcome = outcome
    }
}

/// The promises that hold for every automatic change, whatever the patient looks like.
private func expectLimitsKept(_ changes: [AutoSettingsChange], baseline: [AutoSettingKind: Double]) {
    let limits = AutoSettingsLimits()
    for change in changes where change.reason == .learned {
        let isMore = change.kind.isMoreInsulin(from: change.oldValue, to: change.newValue)
        let cap = isMore ? limits.moreInsulinStep : limits.lessInsulinStep
        let step = abs(change.newValue - change.oldValue)
        // Basal rates move on the pump's 0.05 U/h grid, everything else stays within the cap.
        let allowed = change.kind == .basal ? max(change.oldValue * cap, 0.05) : change.oldValue * cap
        #expect(step <= allowed + 0.000_1, "\(change.kind) moved from \(change.oldValue) to \(change.newValue)")

        if let start = baseline[change.kind] {
            #expect(change.newValue >= start * (1 - limits.band) - 0.000_1, "\(change.kind) left the band: \(change.newValue)")
            #expect(change.newValue <= start * (1 + limits.band) + 0.000_1, "\(change.kind) left the band: \(change.newValue)")
        }
    }

    let learned = changes.filter { $0.reason == .learned }
    for (index, change) in learned.enumerated() {
        for earlier in learned[..<index] {
            let gap = change.date.timeIntervalSince(earlier.date)
            if earlier.key == change.key {
                #expect(gap >= limits.daysBetweenSteps * 86400 - 1, "\(change.kind) stepped twice within three days")
            } else if earlier.kind != change.kind, earlier.kind != .sportRecovery, change.kind != .sportRecovery {
                #expect(gap >= limits.daysBetweenSteps * 86400 - 1, "Two kinds of setting moved within three days")
            }
        }
    }
}

// MARK: - Simulated patients

@Suite("Auto Settings Simulation Tests") struct AutoSettingsSimulationTests {
    private let baseline: [AutoSettingKind: Double] = [.basal: 1.0, .sensitivity: 50, .carbRatio: 10]

    @Test("Settings that deliver too much insulin are led back towards the true needs") func testTooMuchInsulin() {
        let simulation = Simulation(
            truth: .init(basal: 0.85, sensitivity: 58, carbRatio: 11.5),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        simulation.run(days: 80)

        #expect(simulation.basal < 1.0 && simulation.basal >= 0.85 - 0.001, "Basal ended at \(simulation.basal). \(simulation.summary)")
        #expect(simulation.sensitivity > 50 && simulation.sensitivity <= 58 * 1.1, "ISF ended at \(simulation.sensitivity). \(simulation.summary)")
        #expect(simulation.carbRatio > 10 && simulation.carbRatio <= 11.5 * 1.1, "CR ended at \(simulation.carbRatio). \(simulation.summary)")
        #expect(abs(simulation.basal - 0.85) <= 0.05, "Basal ended at \(simulation.basal). \(simulation.summary)")
        #expect(abs(simulation.sensitivity - 58) <= 58 * 0.12, "ISF ended at \(simulation.sensitivity). \(simulation.summary)")
        #expect(abs(simulation.carbRatio - 11.5) <= 11.5 * 0.12, "CR ended at \(simulation.carbRatio). \(simulation.summary)")
        #expect(simulation.applied.allSatisfy { !$0.kind.isMoreInsulin(from: $0.oldValue, to: $0.newValue) })
        expectLimitsKept(simulation.applied, baseline: baseline)
    }

    @Test("Settings that deliver too little insulin are raised, slowly") func testTooLittleInsulin() {
        let simulation = Simulation(
            truth: .init(basal: 1.12, sensitivity: 43, carbRatio: 8.7),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        simulation.run(days: 100)

        #expect(simulation.basal > 1.0 && simulation.basal <= 1.12 + 0.001, "Basal ended at \(simulation.basal). \(simulation.summary)")
        #expect(simulation.sensitivity < 50 && simulation.sensitivity >= 43 * 0.9, "ISF ended at \(simulation.sensitivity). \(simulation.summary)")
        #expect(simulation.carbRatio < 10 && simulation.carbRatio >= 8.7 * 0.9, "CR ended at \(simulation.carbRatio). \(simulation.summary)")
        #expect(simulation.lowestGlucose >= 70, "Raising insulin caused a low: \(simulation.lowestGlucose)")
        expectLimitsKept(simulation.applied, baseline: baseline)
    }

    @Test("Settings that are right are left alone") func testCorrectSettings() {
        let simulation = Simulation(
            truth: .init(basal: 1.0, sensitivity: 50, carbRatio: 10),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        simulation.run(days: 30)

        #expect(simulation.applied.isEmpty, "Changed: \(simulation.applied.map { "\($0.kind) \($0.newValue)" })")
        let verdicts = Set(simulation.state.proposals.map(\.verdict))
        #expect(verdicts == [.matches], "Verdicts: \(verdicts)")
    }

    @Test("A patient outside the band is followed only to its edge") func testBandLimit() {
        let simulation = Simulation(
            truth: .init(basal: 0.85, sensitivity: 50, carbRatio: 10),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        // A narrow band, so the patient's need lies outside it: 0.92 to 1.08 U/h.
        simulation.limits.band = 0.08
        simulation.run(days: 30)

        #expect(abs(simulation.basal - 0.95) < 0.001, "Basal ended at \(simulation.basal). \(simulation.summary)")
        #expect(simulation.state.proposals.first { $0.kind == .basal }?.verdict == .atLimit, "\(simulation.summary)")
        #expect(simulation.applied.count == 1)
    }

    @Test("Shadow mode shows what it would do and changes nothing") func testShadowMode() {
        let simulation = Simulation(
            truth: .init(basal: 0.85, sensitivity: 58, carbRatio: 11.5),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        simulation.settings.mode = .shadow
        simulation.run(days: 20)

        #expect(simulation.applied.isEmpty)
        #expect(simulation.lastOutcome?.changes.isEmpty == true)
        #expect(simulation.basal == 1.0)
        #expect(simulation.state.history.isEmpty)

        let basal = simulation.state.proposals.first { $0.kind == .basal }
        #expect(basal?.verdict == .change)
        #expect(abs((basal?.proposed ?? 0) - 0.95) < 0.001)
        #expect(abs((basal?.estimate ?? 0) - 0.85) < 0.03, "Estimated \(basal?.estimate ?? 0)")
        // Basal goes first, so the other kinds are held back even though they are off as well.
        #expect(simulation.state.proposals.filter { $0.kind != .basal }.allSatisfy { $0.verdict != .change })
    }

    @Test("Switched off, the learner does nothing at all") func testOff() {
        let simulation = Simulation(
            truth: .init(basal: 0.85, sensitivity: 58, carbRatio: 11.5),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        simulation.settings.mode = .off
        simulation.run(days: 10)

        #expect(simulation.applied.isEmpty)
        #expect(simulation.state.proposals.isEmpty)
        #expect(simulation.state.lastRun == nil)
    }

    @Test("With Dynamic ISF on, the sensitivity is not touched") func testDynamicISF() {
        let simulation = Simulation(
            truth: .init(basal: 1.0, sensitivity: 60, carbRatio: 10),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        simulation.settings.mode = .shadow
        simulation.run(days: 20)
        let learned = simulation.state.proposals.first { $0.kind == .sensitivity }
        #expect((learned?.estimate ?? 0) > 50, "Without Dynamic ISF it is estimated. \(simulation.summary)")

        var context = makeContext(now: simulation.now, state: AutoSettingsState(), input: simulation.input)
        context.dynamicISFEnabled = true
        let outcome = AutoSettingsEngine.run(context)
        #expect(outcome.state.proposals.first { $0.kind == .sensitivity }?.verdict == .notAdapted)
        #expect(!outcome.changes.contains { $0.kind == .sensitivity })
    }

    @Test("The recovery phase of a sport profile learns its own percentage") func testSportRecovery() {
        let simulation = Simulation(
            truth: .init(basal: 1.0, sensitivity: 50, carbRatio: 10, recoveryFactor: 0.7),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        simulation.withCorrections = false
        simulation.sportProfile = SportProfile(
            id: "ride",
            name: "Ride",
            phases: [
                SportPhase(id: "during", kind: .during, durationMinutes: 120, percentage: 60, target: 150, smbIsOff: true),
                SportPhase(id: "after", kind: .recovery, durationMinutes: 600, percentage: 90, target: 120, smbIsOff: false)
            ]
        )
        simulation.run(days: 40)

        #expect(simulation.recoveryPercentage < 90, "Recovery ended at \(simulation.recoveryPercentage) %. \(simulation.summary)")
        #expect(simulation.recoveryPercentage >= 70, "Recovery ended at \(simulation.recoveryPercentage) %. \(simulation.summary)")
        #expect(abs(simulation.recoveryPercentage - 70) <= 5, "Recovery ended at \(simulation.recoveryPercentage) %. \(simulation.summary)")
        #expect(simulation.sportProfile?.phases.first?.percentage == 60, "Other phases are not touched")

        // The nights are kept out of the base settings, which are right.
        #expect(simulation.basal == 1.0, "Basal ended at \(simulation.basal). \(simulation.summary)")
        #expect(simulation.applied.allSatisfy { $0.kind == .sportRecovery })
        expectLimitsKept(simulation.applied, baseline: [.sportRecovery: 90])
    }

    @Test("Without the sport log, the same nights would drag the base basal rate down") func testSportExclusionMatters() {
        let simulation = Simulation(
            truth: .init(basal: 1.0, sensitivity: 50, carbRatio: 10, recoveryFactor: 0.85),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        // No meals and no corrections: fasting data all day, most of it from the nights.
        simulation.withCorrections = false
        simulation.meals = []
        simulation.sportProfile = SportProfile(
            id: "ride",
            name: "Ride",
            phases: [SportPhase(id: "after", kind: .recovery, durationMinutes: 600, percentage: 100, target: nil, smbIsOff: false)]
        )
        simulation.settings.adaptSportRecovery = false
        simulation.run(days: 20)
        #expect(simulation.basal == 1.0, "With the log the base rate stays: \(simulation.basal). \(simulation.summary)")

        // The same history, looked at without knowing when sport was.
        let outcome = AutoSettingsEngine.run(makeContext(now: simulation.now, input: simulation.input))
        let blind = outcome.state.proposals.map { "\($0.kind.rawValue): \($0.verdict.rawValue) \($0.estimate ?? 0) n=\($0.sampleCount)" }
        #expect(outcome.changes.contains { $0.kind == .basal && $0.newValue < 1.0 }, "\(blind)")
    }
}

// MARK: - Bookkeeping

@Suite("Auto Settings Engine Tests") struct AutoSettingsEngineTests {
    private let now = dayZero.addingTimeInterval(30 * 86400 + 4 * 3600)

    private func learnedChange(
        _ kind: AutoSettingKind,
        from old: Double,
        to new: Double,
        daysAgo: Double,
        scope changeScope: String = scope
    ) -> AutoSettingsChange {
        let changeKey = AutoSettingsEngine.key(scope: changeScope, kind: kind, blockStartMinute: 0)
        return AutoSettingsChange(
            id: "\(changeKey)-\(daysAgo)",
            date: now.addingTimeInterval(-daysAgo * 86400),
            key: changeKey,
            scope: changeScope,
            scopeName: "Standard",
            kind: kind,
            blockStartMinute: 0,
            oldValue: old,
            newValue: new,
            reason: .learned,
            revertedAt: nil
        )
    }

    /// Flat glucose over the last day with one stretch of low readings.
    private func glucoseWithLow(hoursAgo: Double) -> [BasalTestGlucose] {
        let lowStart = now.addingTimeInterval(-hoursAgo * 3600)
        return (0 ..< 288).map { index in
            let date = now.addingTimeInterval(-Double(288 - index) * 300)
            let isLow = date >= lowStart && date < lowStart.addingTimeInterval(30 * 60)
            return BasalTestGlucose(date: date, value: isLow ? 62 : 110)
        }
    }

    // MARK: Values

    @Test("Therapy settings are read and written block by block") func testTherapyValues() throws {
        let therapy = makeTherapy(basal: 0.85, sensitivity: 45, carbRatio: 9.5)
        let values = AutoSettingsEngine.therapyValues(therapy, profileID: profileID, profileName: "Standard")
        #expect(values.map(\.kind) == [.basal, .sensitivity, .carbRatio])
        #expect(values.map(\.value) == [0.85, 45, 9.5])
        #expect(values[0].key == "therapy:standard|basal|0")

        let basalChange = learnedChange(.basal, from: 0.85, to: 0.8, daysAgo: 0)
        let changed = try #require(AutoSettingsEngine.applying(basalChange, to: therapy, profileID: profileID))
        #expect(changed.basal[0].rate == Decimal(string: "0.8"))
        #expect(changed.basal[0].start == "00:00:00")
        #expect(changed.sensitivities.sensitivities[0].sensitivity == 45)

        let ratioChange = learnedChange(.carbRatio, from: 9.5, to: 9.96, daysAgo: 0)
        let ratio = try #require(AutoSettingsEngine.applying(ratioChange, to: therapy, profileID: profileID))
        #expect(ratio.carbRatios.schedule[0].ratio == Decimal(string: "10.0"), "Carb ratios keep one decimal")

        #expect(AutoSettingsEngine.applying(basalChange, to: therapy, profileID: "other") == nil, "Another profile's change")
        var missingBlock = basalChange
        missingBlock.blockStartMinute = 600
        #expect(AutoSettingsEngine.applying(missingBlock, to: therapy, profileID: profileID) == nil)
    }

    @Test("Only recovery phases of sport profiles are values") func testSportValues() throws {
        let profile = SportProfile(
            id: "run",
            name: "Run",
            phases: [
                SportPhase(id: "a", kind: .pre, durationMinutes: 60, percentage: 80, target: 140, smbIsOff: false),
                SportPhase(id: "b", kind: .recovery, durationMinutes: 300, percentage: 85, target: nil, smbIsOff: false)
            ]
        )
        let values = AutoSettingsEngine.sportValues([profile])
        #expect(values.count == 1)
        #expect(values[0].value == 85)
        #expect(values[0].scope == "sport:run:b")

        let change = learnedChange(.sportRecovery, from: 85, to: 81, daysAgo: 0, scope: "sport:run:b")
        let changed = try #require(AutoSettingsEngine.applying(change, to: [profile]))
        #expect(changed.phases[1].percentage == 81)
        #expect(changed.phases[0].percentage == 80)

        var tooHigh = change
        tooHigh.newValue = 140
        #expect(AutoSettingsEngine.applying(tooHigh, to: [profile])?.phases[1].percentage == 100)
    }

    // MARK: Manual edits

    @Test("A manual edit becomes the new baseline and makes the learner wait") func testManualEdit() {
        var state = AutoSettingsState()
        let before = AutoSettingsEngine.therapyValues(
            makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10), profileID: profileID, profileName: "Standard"
        )
        AutoSettingsEngine.reconcile(&state, values: before, scopePrefix: scope + "|", now: now.addingTimeInterval(-86400))
        #expect(state.anchors[key(.basal)] == 1.0)
        #expect(state.lastChangeAt[key(.basal)] == nil, "Seeing a value for the first time is not a change")

        let after = AutoSettingsEngine.therapyValues(
            makeTherapy(basal: 1.3, sensitivity: 50, carbRatio: 10), profileID: profileID, profileName: "Standard"
        )
        AutoSettingsEngine.reconcile(&state, values: after, scopePrefix: scope + "|", now: now)

        #expect(state.anchors[key(.basal)] == 1.3)
        #expect(state.lastChangeAt[key(.basal)] == now)
        #expect(state.anchors[key(.sensitivity)] == 50)
        #expect(state.lastChangeAt[key(.sensitivity)] == nil)
    }

    @Test("Removed time blocks are forgotten, other profiles are kept") func testReconcilePrunes() {
        var state = AutoSettingsState()
        state.anchors = ["therapy:standard|basal|600": 1.2, "therapy:other|basal|0": 0.7]
        state.lastKnown = state.anchors

        let values = AutoSettingsEngine.therapyValues(
            makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10), profileID: profileID, profileName: "Standard"
        )
        AutoSettingsEngine.reconcile(&state, values: values, scopePrefix: scope + "|", now: now)

        #expect(state.anchors["therapy:standard|basal|600"] == nil)
        #expect(state.anchors["therapy:other|basal|0"] == 0.7)
    }

    @Test("Confirming the baseline centres the band on the current values") func testConfirmBaseline() {
        var state = AutoSettingsState()
        state.anchors[key(.basal)] = 1.0
        let values = AutoSettingsEngine.therapyValues(
            makeTherapy(basal: 0.8, sensitivity: 50, carbRatio: 10), profileID: profileID, profileName: "Standard"
        )
        AutoSettingsEngine.confirmBaseline(&state, values: values)
        #expect(state.anchors[key(.basal)] == 0.8)
    }

    // MARK: Log

    @Test("Recording a change updates what the learner knows") func testRecord() {
        var state = AutoSettingsState()
        let change = learnedChange(.basal, from: 1.0, to: 0.95, daysAgo: 1)
        AutoSettingsEngine.record(change, in: &state)

        #expect(state.history == [change])
        #expect(state.lastKnown[change.key] == 0.95, "So the next run does not mistake it for a manual edit")
        #expect(state.lastChangeAt[change.key] == change.date)
    }

    @Test("Undo restores the old value, marks the change and blocks the value for 14 days") func testUndo() throws {
        var state = AutoSettingsState()
        let change = learnedChange(.basal, from: 1.0, to: 0.95, daysAgo: 1)
        AutoSettingsEngine.record(change, in: &state)

        #expect(AutoSettingsEngine.undoChange(for: change.id, state: state, currentValue: 0.9, now: now) == nil,
                "The value was edited since; there is nothing to take back")
        #expect(AutoSettingsEngine.undoChange(for: "unknown", state: state, currentValue: 0.95, now: now) == nil)

        let undo = try #require(AutoSettingsEngine.undoChange(for: change.id, state: state, currentValue: 0.95, now: now))
        #expect(undo.oldValue == 0.95 && undo.newValue == 1.0)
        #expect(undo.reason == .undone)

        AutoSettingsEngine.record(undo, in: &state)
        #expect(state.history.first?.revertedAt == now)
        #expect(state.blockedUntil[change.key] == now.addingTimeInterval(14 * 86400))
        #expect(state.lastKnown[change.key] == 1.0)
        #expect(AutoSettingsEngine.undoChange(for: change.id, state: state, currentValue: 0.95, now: now) == nil, "Only once")
    }

    @Test("The log keeps the latest 200 changes") func testHistoryLimit() {
        var state = AutoSettingsState()
        for index in 0 ..< 230 {
            AutoSettingsEngine.record(learnedChange(.basal, from: 1, to: 0.95, daysAgo: Double(230 - index)), in: &state)
        }
        #expect(state.history.count == 200)
        #expect(state.history.last?.date == now.addingTimeInterval(-86400))
    }

    // MARK: Lows

    @Test("After a low the latest step towards more insulin is taken back and further ones are paused") func testLowReverts() throws {
        var state = AutoSettingsState()
        state.lastLowCheck = now.addingTimeInterval(-86400)
        AutoSettingsEngine.record(learnedChange(.basal, from: 1.0, to: 1.05, daysAgo: 2), in: &state)
        AutoSettingsEngine.record(learnedChange(.carbRatio, from: 10, to: 10.5, daysAgo: 1), in: &state)

        var input = BasalTestInput()
        input.glucose = glucoseWithLow(hoursAgo: 6)
        let therapy = makeTherapy(basal: 1.05, sensitivity: 50, carbRatio: 10.5)

        let outcome = AutoSettingsEngine.run(makeContext(now: now, state: state, input: input, therapy: therapy))

        let revert = try #require(outcome.changes.first)
        #expect(outcome.changes.count == 1)
        #expect(revert.kind == .basal, "The carb ratio step went towards less insulin and stays")
        #expect(revert.oldValue == 1.05 && revert.newValue == 1.0)
        #expect(revert.reason == .revertedAfterLow)

        let frozenUntil = try #require(outcome.state.frozenUntil)
        #expect(abs(frozenUntil.timeIntervalSince(now.addingTimeInterval(-6 * 3600 + 3 * 86400))) < 1)
        #expect(outcome.state.sportFrozenUntil == nil)
        #expect(outcome.state.lastLowCheck == now)
    }

    @Test("A low is acted on once, and an edited value is not reverted") func testLowOnlyOnce() {
        var state = AutoSettingsState()
        state.lastLowCheck = now.addingTimeInterval(-3600)
        AutoSettingsEngine.record(learnedChange(.basal, from: 1.0, to: 1.05, daysAgo: 2), in: &state)

        var input = BasalTestInput()
        input.glucose = glucoseWithLow(hoursAgo: 6)
        let seen = AutoSettingsEngine.run(
            makeContext(now: now, state: state, input: input, therapy: makeTherapy(basal: 1.05, sensitivity: 50, carbRatio: 10))
        )
        #expect(seen.changes.isEmpty, "The low is older than the last check")

        state.lastLowCheck = now.addingTimeInterval(-86400)
        let edited = AutoSettingsEngine.run(
            makeContext(now: now, state: state, input: input, therapy: makeTherapy(basal: 1.2, sensitivity: 50, carbRatio: 10))
        )
        #expect(edited.changes.isEmpty, "The user set another value in the meantime")
        #expect(edited.state.frozenUntil != nil)
    }

    @Test("Shadow mode notes the low but reverts nothing") func testLowInShadowMode() {
        var state = AutoSettingsState()
        state.lastLowCheck = now.addingTimeInterval(-86400)
        AutoSettingsEngine.record(learnedChange(.basal, from: 1.0, to: 1.05, daysAgo: 2), in: &state)
        var input = BasalTestInput()
        input.glucose = glucoseWithLow(hoursAgo: 6)

        let outcome = AutoSettingsEngine.run(makeContext(
            now: now, mode: .shadow, state: state, input: input, therapy: makeTherapy(basal: 1.05, sensitivity: 50, carbRatio: 10)
        ))
        #expect(outcome.changes.isEmpty)
        #expect(outcome.state.frozenUntil != nil)
    }

    @Test("A low after sport pauses the sport profile, not the base settings") func testSportLow() throws {
        var state = AutoSettingsState()
        state.lastLowCheck = now.addingTimeInterval(-86400)
        state.sportSpans = [AutoSettingsSportSpan(
            profileID: "run", phaseID: "b", start: now.addingTimeInterval(-10 * 3600), end: now.addingTimeInterval(-8 * 3600)
        )]
        AutoSettingsEngine.record(learnedChange(.basal, from: 1.0, to: 1.05, daysAgo: 2), in: &state)
        AutoSettingsEngine.record(
            learnedChange(.sportRecovery, from: 80, to: 82, daysAgo: 3, scope: "sport:run:b"), in: &state
        )

        var input = BasalTestInput()
        input.glucose = glucoseWithLow(hoursAgo: 6)
        var context = makeContext(now: now, state: state, input: input, therapy: makeTherapy(basal: 1.05, sensitivity: 50, carbRatio: 10))
        context.sportProfiles = [SportProfile(
            id: "run",
            name: "Run",
            phases: [SportPhase(id: "b", kind: .recovery, durationMinutes: 300, percentage: 82, target: nil, smbIsOff: false)]
        )]

        let outcome = AutoSettingsEngine.run(context)

        let revert = try #require(outcome.changes.first)
        #expect(outcome.changes.count == 1)
        #expect(revert.kind == .sportRecovery)
        #expect(revert.newValue == 80)
        #expect(outcome.state.sportFrozenUntil != nil)
        #expect(outcome.state.frozenUntil == nil, "Two hours after sport, within the 12 hour after-effect")
    }

    // MARK: Spans

    @Test("The sport log follows the running profile phase by phase") func testSyncSportSpans() {
        let profile = SportProfile(
            id: "run",
            name: "Run",
            phases: [
                SportPhase(id: "a", kind: .during, durationMinutes: 60, percentage: 60, target: nil, smbIsOff: true),
                SportPhase(id: "b", kind: .recovery, durationMinutes: 300, percentage: 85, target: nil, smbIsOff: false)
            ]
        )
        func run(phase: Int, startedAt: Date) -> SportProfileRun {
            SportProfileRun(
                profileID: "run", profileName: "Run", phaseIndex: phase, phaseStartedAt: startedAt,
                phaseDurationMinutes: 60, overrideID: "x", startedAt: now
            )
        }
        var state = AutoSettingsState()

        #expect(!AutoSettingsEngine.syncSportSpans(&state, run: nil, profiles: [profile], now: now))

        #expect(AutoSettingsEngine.syncSportSpans(&state, run: run(phase: 0, startedAt: now), profiles: [profile], now: now))
        #expect(state.sportSpans.count == 1)
        #expect(!AutoSettingsEngine.syncSportSpans(&state, run: run(phase: 0, startedAt: now), profiles: [profile], now: now),
                "Nothing new")

        let phaseTwo = now.addingTimeInterval(3600)
        #expect(AutoSettingsEngine.syncSportSpans(&state, run: run(phase: 1, startedAt: phaseTwo), profiles: [profile], now: phaseTwo))
        #expect(state.sportSpans.count == 2)
        #expect(state.sportSpans[0].end == phaseTwo)
        #expect(state.sportSpans[1].phaseID == "b")

        let finished = now.addingTimeInterval(5 * 3600)
        #expect(AutoSettingsEngine.syncSportSpans(&state, run: nil, profiles: [profile], now: finished))
        #expect(state.sportSpans[1].end == finished)
        #expect(!AutoSettingsEngine.syncSportSpans(&state, run: nil, profiles: [profile], now: finished))
    }

    @Test("The profile log starts in the past and records each switch") func testSyncProfileSpans() {
        var state = AutoSettingsState()
        #expect(AutoSettingsEngine.syncProfileSpans(&state, activeProfileID: "a", now: now))
        #expect(state.profileSpans.count == 1)
        #expect(state.profileSpans[0].start < now.addingTimeInterval(-30 * 86400), "The first profile is assumed to be old")
        #expect(!AutoSettingsEngine.syncProfileSpans(&state, activeProfileID: "a", now: now))

        let later = now.addingTimeInterval(86400)
        #expect(AutoSettingsEngine.syncProfileSpans(&state, activeProfileID: "b", now: later))
        #expect(state.profileSpans[0].end == later)
        #expect(state.profileSpans[1].start == later)
        #expect(state.profileSpans[1].end == nil)
    }

    @Test("Time under another therapy profile does not count for the active one") func testOtherProfileExcluded() {
        let simulation = Simulation(
            truth: .init(basal: 0.85, sensitivity: 50, carbRatio: 10),
            therapy: makeTherapy(basal: 1.0, sensitivity: 50, carbRatio: 10)
        )
        simulation.settings.mode = .shadow
        simulation.run(days: 10)
        #expect(simulation.state.proposals.first { $0.kind == .basal }?.verdict == .change)

        // The same history, but all of it belongs to a profile that is no longer active.
        var state = AutoSettingsState()
        state.profileSpans = [
            AutoSettingsProfileSpan(profileID: "training", start: dayZero.addingTimeInterval(-86400), end: simulation.now),
            AutoSettingsProfileSpan(profileID: profileID, start: simulation.now, end: nil)
        ]
        let outcome = AutoSettingsEngine.run(makeContext(now: simulation.now, mode: .shadow, state: state, input: simulation.input))
        #expect(outcome.state.proposals.first { $0.kind == .basal }?.verdict == .notEnoughData)
    }
}
