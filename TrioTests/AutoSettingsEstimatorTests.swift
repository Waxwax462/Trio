import Foundation
import Testing

@testable import Trio

@Suite("Auto Settings Estimator Tests") struct AutoSettingsEstimatorTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Midnight UTC.
    private let dayZero = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400))
    private let model = InsulinActionModel(peakMinutes: 75, durationMinutes: 360)

    private func time(hour: Int, minute: Int = 0) -> Date {
        dayZero.addingTimeInterval(Double(hour * 60 + minute) * 60)
    }

    /// Readings every five minutes; `value` gets the minutes since `from`.
    private func readings(from: Date, to: Date, value: (Double) -> Double) -> [BasalTestGlucose] {
        var result: [BasalTestGlucose] = []
        var date = from
        while date <= to {
            result.append(BasalTestGlucose(date: date, value: value(date.timeIntervalSince(from) / 60)))
            date = date.addingTimeInterval(300)
        }
        return result
    }

    private func baseInput() -> BasalTestInput {
        var input = BasalTestInput()
        input.basalSchedule = [BasalTestScheduleEntry(startMinute: 0, value: 1.0)]
        input.sensitivitySchedule = [BasalTestScheduleEntry(startMinute: 0, value: 50)]
        input.carbRatioSchedule = [BasalTestScheduleEntry(startMinute: 0, value: 10)]
        return input
    }

    // MARK: - Insulin action

    @Test("A dose is fully there at the start, used up at the end and only ever shrinks") func testRemaining() {
        #expect(model.remaining(after: 0) == 1)
        #expect(model.remaining(after: -10) == 1)
        #expect(model.remaining(after: 360) == 0)
        #expect(model.remaining(after: 500) == 0)

        var previous = 1.0
        for minute in stride(from: 5.0, through: 360.0, by: 5.0) {
            let value = model.remaining(after: minute)
            #expect(value <= previous + 0.000_001, "Not falling at minute \(minute)")
            #expect(value >= 0 && value <= 1)
            previous = value
        }
        #expect(model.remaining(after: 355) < 0.01, "The curve runs out smoothly")
        #expect(model.remaining(after: 75) > 0.6 && model.remaining(after: 75) < 0.9)
    }

    @Test("Absorbed insulin adds up to the dose") func testAbsorbed() {
        let dose = [InsulinDose(date: time(hour: 12), units: 2)]

        let whole = InsulinAccounting.absorbed(dose, in: BasalTestSpan(start: time(hour: 12), end: time(hour: 18)), model: model)
        #expect(abs(whole - 2) < 0.000_1)

        let first = InsulinAccounting.absorbed(dose, in: BasalTestSpan(start: time(hour: 12), end: time(hour: 14)), model: model)
        let second = InsulinAccounting.absorbed(dose, in: BasalTestSpan(start: time(hour: 14), end: time(hour: 18)), model: model)
        #expect(abs(first + second - 2) < 0.000_1)
        #expect(first > second, "Most of a dose acts in the first two hours")

        let before = InsulinAccounting.absorbed(dose, in: BasalTestSpan(start: time(hour: 8), end: time(hour: 12)), model: model)
        #expect(before == 0)
    }

    @Test("Net insulin is what was delivered above or below the schedule") func testNetDoses() {
        var input = baseInput()
        input.boluses = [BasalTestBolus(date: time(hour: 10, minute: 2), units: 1.5, isAutomatic: false)]
        input.tempBasals = [
            BasalTestTempBasal(start: time(hour: 10), durationMinutes: 30, rate: 2.0, isScheduledBasal: false),
            BasalTestTempBasal(start: time(hour: 11), durationMinutes: 30, rate: 0, isScheduledBasal: false)
        ]

        let doses = InsulinAccounting.netDoses(input, from: time(hour: 9), to: time(hour: 13), calendar: calendar)
        let total = doses.reduce(0) { $0 + $1.units }

        // +0.5 U from the high temp basal, -0.5 U from the zero temp basal, 1.5 U bolus.
        #expect(abs(total - 1.5) < 0.001)
        #expect(doses.contains { $0.units < 0 })
        #expect(doses == doses.sorted { $0.date < $1.date })

        let above = doses.filter { $0.date >= time(hour: 10) && $0.date < time(hour: 10, minute: 30) && $0.units < 1 }
        #expect(abs(above.reduce(0) { $0 + $1.units } - 0.5) < 0.001)
    }

    // MARK: - Insulin sensitivity

    @Test("A correction without food shows the true sensitivity") func testSensitivitySample() {
        let trueSensitivity = 60.0
        let bolusTime = time(hour: 12)
        var input = baseInput()
        input.boluses = [BasalTestBolus(date: bolusTime, units: 2, isAutomatic: false)]
        input.glucose = readings(from: time(hour: 6), to: time(hour: 18)) { minutes in
            let sinceBolus = minutes - 360
            return 220 - trueSensitivity * 2 * (1 - model.remaining(after: sinceBolus))
        }

        let doses = InsulinAccounting.netDoses(input, from: time(hour: 0), to: time(hour: 18), calendar: calendar)
        let samples = SensitivityEstimator.sensitivitySamples(input, doses: doses, model: model, calendar: calendar)

        #expect(!samples.isEmpty)
        for sample in samples {
            #expect(abs(sample.value - trueSensitivity) < trueSensitivity * 0.1, "Got \(sample.value)")
            #expect(sample.blockStartMinute == 0)
        }
        // Episodes do not overlap.
        for (first, second) in zip(samples, samples.dropFirst()) {
            #expect(second.date.timeIntervalSince(first.date) >= 90 * 60)
        }
    }

    @Test("Carbs, low starting values and missing insulin give no sensitivity sample") func testSensitivityFilters() {
        let bolusTime = time(hour: 12)
        func input(start: Double, carbs: Bool, units: Double) -> BasalTestInput {
            var input = baseInput()
            input.boluses = units > 0 ? [BasalTestBolus(date: bolusTime, units: units, isAutomatic: false)] : []
            input.glucose = readings(from: time(hour: 6), to: time(hour: 18)) { minutes in
                start - 50 * units * (1 - model.remaining(after: minutes - 360))
            }
            if carbs {
                input.carbDates = [time(hour: 11)]
                input.carbs = [BasalTestCarb(date: time(hour: 11), grams: 30)]
            }
            return input
        }
        func count(_ input: BasalTestInput) -> Int {
            let doses = InsulinAccounting.netDoses(input, from: time(hour: 0), to: time(hour: 18), calendar: calendar)
            return SensitivityEstimator.sensitivitySamples(input, doses: doses, model: model, calendar: calendar).count
        }

        #expect(count(input(start: 220, carbs: false, units: 2)) > 0)
        #expect(count(input(start: 220, carbs: true, units: 2)) == 0, "Carbs an hour before spoil the correction")
        #expect(count(input(start: 130, carbs: false, units: 0.5)) == 0, "Glucose never high enough")
        #expect(count(input(start: 220, carbs: false, units: 0)) == 0, "No insulin, no quotient")
    }

    // MARK: - Carb ratio

    private func mealInput(trueCarbRatio: Double, grams: Double, bolus: Double, startGlucose: Double = 120) -> BasalTestInput {
        let mealTime = time(hour: 12)
        var input = baseInput()
        input.carbDates = [mealTime]
        input.carbs = [BasalTestCarb(date: mealTime, grams: grams)]
        input.boluses = [BasalTestBolus(date: mealTime, units: bolus, isAutomatic: false)]
        // Sensitivity 50; carbs raise glucose evenly over three hours.
        let rise = grams * 50 / trueCarbRatio
        input.glucose = readings(from: time(hour: 6), to: time(hour: 18)) { minutes in
            let sinceMeal = minutes - 360
            guard sinceMeal > 0 else { return startGlucose }
            return startGlucose + rise * min(sinceMeal / 180, 1) - 50 * bolus * (1 - model.remaining(after: sinceMeal))
        }
        return input
    }

    private func carbRatioSamples(_ input: BasalTestInput) -> [SettingSample] {
        let doses = InsulinAccounting.netDoses(input, from: time(hour: 0), to: time(hour: 18), calendar: calendar)
        return SensitivityEstimator.carbRatioSamples(input, doses: doses, model: model, calendar: calendar)
    }

    @Test("An isolated meal shows the true carb ratio, whichever way the bolus was off") func testCarbRatioSample() throws {
        // Bolused with 1:10, although 1:12.5 would have been right: too much insulin.
        let tooMuch = try #require(carbRatioSamples(mealInput(trueCarbRatio: 12.5, grams: 50, bolus: 5)).first)
        #expect(abs(tooMuch.value - 12.5) < 0.7, "Got \(tooMuch.value)")

        // Bolused with 1:10, although 1:8 would have been right: too little insulin.
        let tooLittle = try #require(carbRatioSamples(mealInput(trueCarbRatio: 8, grams: 50, bolus: 5, startGlucose: 110)).first)
        #expect(abs(tooLittle.value - 8) < 0.5, "Got \(tooLittle.value)")
    }

    @Test("Small meals, snacks in between and lows before the meal give no carb ratio sample") func testCarbRatioFilters() {
        #expect(carbRatioSamples(mealInput(trueCarbRatio: 10, grams: 50, bolus: 5)).count == 1)
        #expect(carbRatioSamples(mealInput(trueCarbRatio: 10, grams: 10, bolus: 1)).isEmpty, "Too few carbs")

        var snack = mealInput(trueCarbRatio: 10, grams: 50, bolus: 5)
        snack.carbDates.append(time(hour: 14))
        snack.carbs.append(BasalTestCarb(date: time(hour: 14), grams: 20))
        #expect(carbRatioSamples(snack).isEmpty, "A snack inside the window")

        var fat = mealInput(trueCarbRatio: 10, grams: 50, bolus: 5)
        fat.carbDates.append(time(hour: 13))
        #expect(carbRatioSamples(fat).isEmpty, "Fat and protein equivalents count as food")

        var override = mealInput(trueCarbRatio: 10, grams: 50, bolus: 5)
        override.adjustments = [BasalTestSpan(start: time(hour: 13), end: time(hour: 14))]
        #expect(carbRatioSamples(override).isEmpty, "An override inside the window")

        var lowBefore = mealInput(trueCarbRatio: 10, grams: 50, bolus: 5)
        lowBefore.glucose = lowBefore.glucose.map {
            $0.date >= time(hour: 10) && $0.date < time(hour: 10, minute: 20) ? BasalTestGlucose(date: $0.date, value: 62) : $0
        }
        #expect(carbRatioSamples(lowBefore).isEmpty, "A low before the meal")
    }

    @Test("A meal that ends in a low still shows that it got too much insulin") func testCarbRatioWithLateLow() throws {
        // 1:10 bolused where 1:14 was right, starting at 95: glucose goes low after about three hours.
        let input = mealInput(trueCarbRatio: 14, grams: 60, bolus: 6, startGlucose: 95)
        let firstLow = try #require(input.glucose.first { $0.value < 70 })
        #expect(firstLow.date > time(hour: 14), "The scenario is meant to go low late")

        let sample = try #require(carbRatioSamples(input).first)
        #expect(sample.value > 11, "The sample points towards less insulin, got \(sample.value)")
    }

    @Test("Samples are assigned to the time block they fall into") func testBlocks() {
        let schedule = [
            BasalTestScheduleEntry(startMinute: 0, value: 10),
            BasalTestScheduleEntry(startMinute: 11 * 60, value: 8),
            BasalTestScheduleEntry(startMinute: 17 * 60, value: 12)
        ]
        #expect(SensitivityEstimator.blockStart(at: time(hour: 3), schedule: schedule, calendar: calendar) == 0)
        #expect(SensitivityEstimator.blockStart(at: time(hour: 12), schedule: schedule, calendar: calendar) == 11 * 60)
        #expect(SensitivityEstimator.blockStart(at: time(hour: 23), schedule: schedule, calendar: calendar) == 17 * 60)
    }
}
