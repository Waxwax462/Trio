import Foundation
import Testing

@testable import Trio

@Suite("Auto Settings Policy Tests") struct AutoSettingsPolicyTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let limits = AutoSettingsLimits()

    /// One sample per day, going back from yesterday.
    private func samples(_ values: [Double]) -> [SettingSample] {
        values.enumerated().map { index, value in
            SettingSample(date: now.addingTimeInterval(-Double(index + 1) * 86400), blockStartMinute: 0, value: value)
        }
    }

    private func decide(
        kind: AutoSettingKind = .basal,
        current: Double = 1.0,
        anchor: Double? = nil,
        samples: [SettingSample],
        lastChange: Date? = nil,
        blockedUntil: Date? = nil,
        frozen: Bool = false,
        grid: AutoSettingsGrid = .step(0.01),
        range: ClosedRange<Double> = 0.05 ... 10
    ) -> AutoSettingsDecision {
        AutoSettingsPolicy.decide(
            kind: kind,
            current: current,
            anchor: anchor ?? current,
            samples: samples,
            lastChange: lastChange,
            blockedUntil: blockedUntil,
            moreInsulinFrozen: frozen,
            grid: grid,
            hardRange: range,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Evidence

    @Test("Too few samples or too few days change nothing") func testNotEnoughData() {
        #expect(decide(samples: []).verdict == .notEnoughData)
        #expect(decide(samples: samples([0.8, 0.8])).verdict == .notEnoughData)

        let sameDay = (0 ..< 5).map {
            SettingSample(date: now.addingTimeInterval(-Double($0) * 600), blockStartMinute: 0, value: 0.8)
        }
        let decision = decide(samples: sameDay)
        #expect(decision.verdict == .notEnoughData, "Five samples from one day are one observation")
        #expect(decision.estimate == 0.8)
    }

    @Test("An estimate close to the current value counts as a match") func testMatches() {
        #expect(decide(samples: samples([1.02, 0.98, 1.03])).verdict == .matches)
        #expect(decide(kind: .sensitivity, current: 50, samples: samples([54, 54, 53, 54, 54]), grid: .step(1), range: 9 ... 540)
            .verdict == .matches, "Sensitivity has a wider dead band")
    }

    @Test("Samples that disagree are inconclusive") func testInconclusive() {
        // Median 0.8, but only five of eight samples are below the current value.
        #expect(decide(samples: samples([0.7, 0.8, 0.8, 0.75, 0.78, 1.2, 1.3, 1.2])).verdict == .inconclusive)
    }

    // MARK: - Step size

    @Test("Less insulin moves by at most 5 %") func testLessInsulinStep() {
        let decision = decide(samples: samples([0.7, 0.72, 0.68]))
        #expect(decision.verdict == .change)
        #expect(decision.proposed == 0.95)
        #expect(decision.estimate == 0.7)
    }

    @Test("More insulin moves by at most 2.5 % and needs more evidence") func testMoreInsulinStep() {
        #expect(decide(samples: samples([1.3, 1.3, 1.3])).verdict == .notEnoughData, "Three samples are enough only for less insulin")
        #expect(decide(samples: samples([1.3, 1.3, 1.3, 1.3, 0.9])).verdict == .inconclusive, "80 % agreement is not enough")

        let decision = decide(samples: samples([1.3, 1.3, 1.3, 1.3, 1.3]))
        #expect(decision.verdict == .change)
        #expect(abs((decision.proposed ?? 0) - 1.02) < 0.000_1, "1.025 rounded towards the current value")
    }

    @Test("Direction of more insulin depends on the kind of setting") func testDirections() {
        #expect(AutoSettingKind.basal.isMoreInsulin(from: 1, to: 1.1))
        #expect(AutoSettingKind.sportRecovery.isMoreInsulin(from: 70, to: 75))
        #expect(AutoSettingKind.sensitivity.isMoreInsulin(from: 50, to: 45))
        #expect(AutoSettingKind.carbRatio.isMoreInsulin(from: 10, to: 9))
        #expect(!AutoSettingKind.sensitivity.isMoreInsulin(from: 50, to: 55))

        // A lower sensitivity value is more insulin: capped at 2.5 %.
        let stronger = decide(
            kind: .sensitivity, current: 80, samples: samples([60, 60, 60, 60, 60, 60, 60]), grid: .step(1), range: 9 ... 540
        )
        #expect(stronger.proposed == 78)

        // A higher sensitivity value is less insulin: capped at 5 %.
        let weaker = decide(kind: .sensitivity, current: 80, samples: samples([100, 100, 100, 100, 100]), grid: .step(1), range: 9 ... 540)
        #expect(weaker.proposed == 84)
    }

    // MARK: - Grid

    @Test("A grid coarser than the step moves by one grid value, if the estimate is that far away") func testCoarseGrid() {
        let rates = (1 ... 200).map { Double($0) * 0.05 }

        // 0.50 U/h on a 0.05 grid: 5 % would be 0.475, which the pump cannot do.
        let far = decide(current: 0.5, samples: samples([0.40, 0.42, 0.44]), grid: .values(rates))
        #expect(far.verdict == .change)
        #expect(abs((far.proposed ?? 0) - 0.45) < 0.000_1)

        // The estimate is only 0.03 away: one increment would overshoot it.
        let near = decide(current: 0.5, samples: samples([0.47, 0.47, 0.47]), grid: .values(rates))
        #expect(near.verdict == .matches)
        #expect(near.proposed == nil)

        let up = decide(current: 0.5, samples: samples([0.56, 0.56, 0.57, 0.56, 0.58]), grid: .values(rates))
        #expect(abs((up.proposed ?? 0) - 0.55) < 0.000_1)
    }

    @Test("Quantizing never goes past the target on a fine grid") func testQuantized() {
        #expect(AutoSettingsPolicy.quantized(target: 52.5, current: 50, estimate: 60, grid: .step(1)) == 52)
        #expect(AutoSettingsPolicy.quantized(target: 48.75, current: 50, estimate: 40, grid: .step(1)) == 49)
        #expect(abs((AutoSettingsPolicy.quantized(target: 10.5, current: 10, estimate: 12, grid: .step(0.1)) ?? 0) - 10.5) < 0.000_1)
        #expect(AutoSettingsPolicy.quantized(target: 50.4, current: 50, estimate: 50.4, grid: .step(1)) == nil)
        #expect(AutoSettingsPolicy.quantized(target: 50.4, current: 50, estimate: 51.2, grid: .step(1)) == 51)
    }

    // MARK: - Limits

    @Test("A value never leaves the band around its baseline") func testBand() {
        // Baseline 1.0, already at 0.80.
        let atEdge = decide(current: 0.80, anchor: 1.0, samples: samples([0.6, 0.6, 0.6]))
        #expect(atEdge.verdict == .atLimit)
        #expect(atEdge.proposed == nil)

        // One step left to the edge.
        let nearEdge = decide(current: 0.82, anchor: 1.0, samples: samples([0.6, 0.6, 0.6]))
        #expect(nearEdge.verdict == .change)
        #expect(abs((nearEdge.proposed ?? 0) - 0.80) < 0.000_1)

        let upperEdge = decide(current: 1.20, anchor: 1.0, samples: samples([1.5, 1.5, 1.5, 1.5, 1.5]))
        #expect(upperEdge.verdict == .atLimit)
    }

    @Test("The hard range of a setting is respected") func testHardRange() {
        let decision = decide(
            kind: .sportRecovery, current: 100, samples: samples([130, 130, 130, 130, 130]), grid: .step(1), range: 10 ... 100
        )
        #expect(decision.verdict == .atLimit, "Sport profiles never go above 100 %")
    }

    @Test("After a step the value rests for three days") func testWaiting() {
        let recent = decide(samples: samples([0.7, 0.7, 0.7]), lastChange: now.addingTimeInterval(-2 * 86400))
        #expect(recent.verdict == .waiting)
        #expect(recent.proposed == 0.95, "The pending step is still shown, without binary noise")

        let old = decide(samples: samples([0.7, 0.7, 0.7]), lastChange: now.addingTimeInterval(-3.1 * 86400))
        #expect(old.verdict == .change)
    }

    @Test("After a low only steps towards more insulin are paused") func testFrozen() {
        #expect(decide(samples: samples([1.3, 1.3, 1.3, 1.3, 1.3]), frozen: true).verdict == .frozen)
        #expect(decide(samples: samples([0.7, 0.7, 0.7]), frozen: true).verdict == .change)
    }

    @Test("A value the user restored is left alone") func testBlocked() {
        #expect(decide(samples: samples([0.7, 0.7, 0.7]), blockedUntil: now.addingTimeInterval(86400)).verdict == .blocked)
        #expect(decide(samples: samples([0.7, 0.7, 0.7]), blockedUntil: now.addingTimeInterval(-86400)).verdict == .change)
    }

    // MARK: - Lows

    private func glucose(_ values: [Double], start: Date) -> [BasalTestGlucose] {
        values.enumerated().map { BasalTestGlucose(date: start.addingTimeInterval(Double($0.offset) * 300), value: $0.element) }
    }

    @Test("A low is three readings below 70 in a row or one below 54") func testLowEvents() {
        let start = now.addingTimeInterval(-6 * 3600)
        let before = start.addingTimeInterval(-1)

        #expect(AutoSettingsPolicy.lowEvents(glucose([90, 68, 66, 90, 69, 90], start: start), after: before).isEmpty)
        #expect(AutoSettingsPolicy.lowEvents(glucose([90, 68, 66, 65, 64, 90], start: start), after: before)
            == [start.addingTimeInterval(300)], "One event, dated at the first low reading")
        #expect(AutoSettingsPolicy.lowEvents(glucose([90, 52, 90], start: start), after: before).count == 1)
        #expect(AutoSettingsPolicy.lowEvents(glucose([90, 52, 90], start: start), after: now).isEmpty, "Older than the cut-off")
    }

    @Test("Lows close together count once, lows hours apart count separately") func testLowEventsMerge() {
        let start = now.addingTimeInterval(-12 * 3600)
        var values = [Double](repeating: 100, count: 100)
        values[5] = 50
        values[9] = 50 // 20 minutes later: same event
        values[60] = 50 // hours later: a new one
        #expect(AutoSettingsPolicy.lowEvents(glucose(values, start: start), after: start.addingTimeInterval(-1)).count == 2)
    }
}
