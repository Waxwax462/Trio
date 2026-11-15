import Foundation
import Testing

@testable import Trio

// MARK: - Fixtures

private func dec(_ string: String) -> Decimal {
    Decimal(string: string)!
}

private func isClose(_ lhs: Decimal, _ rhs: Decimal) -> Bool {
    abs(lhs - rhs) < dec("0.0001")
}

private func startString(_ minutes: Int) -> String {
    String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
}

private func makeSettings(
    basal: [(Int, String)] = [(0, "1.0")],
    sensitivity: String = "50",
    carbRatio: String = "10",
    target: String = "100"
) -> TherapySettingsSnapshot {
    TherapySettingsSnapshot(
        basal: basal.map { BasalProfileEntry(start: startString($0.0), minutes: $0.0, rate: dec($0.1)) },
        sensitivities: InsulinSensitivities(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            sensitivities: [InsulinSensitivityEntry(sensitivity: dec(sensitivity), offset: 0, start: startString(0))]
        ),
        carbRatios: CarbRatios(
            units: .grams,
            schedule: [CarbRatioEntry(start: startString(0), offset: 0, ratio: dec(carbRatio))]
        ),
        targets: BGTargets(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            targets: [BGTargetEntry(low: dec(target), high: dec(target), start: startString(0), offset: 0)]
        )
    )
}

/// Multiples of 0.05 U/hr up to 10 U/hr.
private let pumpRates: [Decimal] = (1 ... 200).map { Decimal($0) / 20 }

// MARK: - Rules

@Suite("Therapy Profile Logic Tests") struct TherapyProfileLogicTests {
    @Test("Scaling to 80% lowers basal and raises ISF and carb ratio") func testScaleDown() {
        let scaled = TherapyProfileLogic.scaled(makeSettings(), percentage: 80, supportedBasalRates: pumpRates)

        #expect(isClose(scaled.basal[0].rate, dec("0.8")))
        #expect(isClose(scaled.sensitivities.sensitivities[0].sensitivity, dec("63")))
        #expect(isClose(scaled.carbRatios.schedule[0].ratio, dec("12.5")))
        #expect(isClose(scaled.targets.targets[0].low, dec("100")), "Targets are not scaled")
    }

    @Test("Scaling to 100% changes nothing") func testScaleIdentity() {
        let original = makeSettings(basal: [(0, "0.85"), (360, "1.15")])
        let scaled = TherapyProfileLogic.scaled(original, percentage: 100, supportedBasalRates: pumpRates)
        #expect(TherapyProfileLogic.differences(from: original, to: scaled).isEmpty)
    }

    @Test("Scaled basal lands on a rate the pump supports") func testScaledBasalIsSupported() {
        let scaled = TherapyProfileLogic.scaled(
            makeSettings(basal: [(0, "0.85")]),
            percentage: 85,
            supportedBasalRates: pumpRates
        )
        // 0.85 * 0.85 = 0.7225, nearest supported rate is 0.70
        #expect(isClose(scaled.basal[0].rate, dec("0.7")))
        #expect(TherapyProfileLogic.isSupported(scaled.basal[0].rate, supportedBasalRates: pumpRates))
    }

    @Test("Basal rounding never returns zero") func testBasalRoundingFloor() {
        #expect(isClose(TherapyProfileLogic.roundedBasalRate(dec("0.01"), supportedBasalRates: nil), dec("0.05")))
        #expect(isClose(TherapyProfileLogic.roundedBasalRate(dec("0.01"), supportedBasalRates: pumpRates), dec("0.05")))
        #expect(isClose(TherapyProfileLogic.roundedBasalRate(dec("0.72"), supportedBasalRates: nil), dec("0.7")))
    }

    @Test("Percentage is limited to 50–150") func testPercentageClamp() {
        let scaled = TherapyProfileLogic.scaled(makeSettings(), percentage: 10, supportedBasalRates: pumpRates)
        #expect(isClose(scaled.basal[0].rate, dec("0.5")))
    }

    @Test("Valid settings pass validation") func testValidSettings() {
        let problems = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "0.8"), (360, "1.0")]),
            supportedBasalRates: pumpRates,
            maxBasal: 2
        )
        #expect(problems.isEmpty)
    }

    @Test("Validation finds each kind of problem") func testValidationProblems() {
        let zeroRate = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "0")]),
            supportedBasalRates: pumpRates,
            maxBasal: nil
        )
        #expect(zeroRate.contains(.valueOutOfRange(.basal, minutes: 0, value: 0)))

        let unsupported = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "0.83")]),
            supportedBasalRates: pumpRates,
            maxBasal: nil
        )
        #expect(unsupported.contains(.basalRateNotSupportedByPump(minutes: 0, value: dec("0.83"))))

        let aboveMax = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "3.0")]),
            supportedBasalRates: pumpRates,
            maxBasal: 2
        )
        #expect(aboveMax.contains(.basalRateAboveMaxBasal(minutes: 0, value: dec("3.0"))))

        let lateStart = TherapyProfileLogic.validate(
            makeSettings(basal: [(60, "1.0")]),
            supportedBasalRates: pumpRates,
            maxBasal: nil
        )
        #expect(lateStart.contains(.scheduleDoesNotStartAtMidnight(.basal)))

        let unordered = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "1.0"), (600, "1.0"), (300, "1.0")]),
            supportedBasalRates: pumpRates,
            maxBasal: nil
        )
        #expect(unordered.contains(.scheduleNotAscending(.basal)))

        var empty = makeSettings()
        empty.basal = []
        #expect(TherapyProfileLogic.validate(empty, supportedBasalRates: nil, maxBasal: nil).contains(.emptySchedule(.basal)))

        let lowSensitivity = TherapyProfileLogic.validate(
            makeSettings(sensitivity: "5"),
            supportedBasalRates: nil,
            maxBasal: nil
        )
        #expect(lowSensitivity.contains(.valueOutOfRange(.sensitivity, minutes: 0, value: 5)))
    }

    @Test("Differences list the times at which values change") func testDifferences() {
        let old = makeSettings(basal: [(0, "1.0")])
        let new = makeSettings(basal: [(0, "1.0"), (360, "0.8")], sensitivity: "60")

        let differences = TherapyProfileLogic.differences(from: old, to: new)

        #expect(differences.count == 2)
        let basal = differences.first { $0.category == .basal }
        #expect(basal?.minutes == 360)
        #expect(basal?.oldValue.map { isClose($0, dec("1.0")) } == true)
        #expect(basal?.newValue.map { isClose($0, dec("0.8")) } == true)
        #expect(differences.contains { $0.category == .sensitivity && $0.minutes == 0 })
    }

    @Test("Daily basal sums every segment") func testDailyBasal() {
        // 6 h at 1.0 + 18 h at 0.5 = 15 U
        let total = TherapyProfileLogic.dailyBasal(makeSettings(basal: [(0, "1.0"), (360, "0.5")]).basal)
        #expect(isClose(total, dec("15")))
    }
}
