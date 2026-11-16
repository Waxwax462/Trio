import Foundation

// MARK: - Insulin action

/// The exponential insulin activity curve the algorithm uses, reduced to the one question the
/// settings learner asks: how much of a dose has been absorbed after a given time.
struct InsulinActionModel: Equatable {
    /// Minutes until the activity peaks: 75 for rapid-acting, 55 for ultra-rapid insulin.
    var peakMinutes: Double = 75
    /// Minutes until a dose is used up.
    var durationMinutes: Double = 360

    /// The share of a dose that is still unabsorbed `minutes` after it was given.
    func remaining(after minutes: Double) -> Double {
        guard minutes > 0 else { return 1 }
        let duration = max(durationMinutes, 180)
        guard minutes < duration else { return 0 }
        // The curve is only defined for a peak in the first half of the duration.
        let peak = min(max(peakMinutes, 35), duration * 0.45)

        let tau = peak * (1 - peak / duration) / (1 - 2 * peak / duration)
        let a = 2 * tau / duration
        let scale = 1 / (1 - a + (1 + a) * exp(-duration / tau))
        let value = 1 - scale * (1 - a)
            * ((minutes * minutes / (tau * duration * (1 - a)) - minutes / tau - 1) * exp(-minutes / tau) + 1)
        return min(max(value, 0), 1)
    }
}

/// An amount of insulin at a moment. Negative when less than the scheduled basal was delivered.
struct InsulinDose: Equatable {
    let date: Date
    let units: Double
}

enum InsulinAccounting {
    static let stepMinutes: Double = 5

    /// All insulin relative to the scheduled basal rate: boluses, plus what temp basals and
    /// suspensions delivered above or below the schedule, in five-minute portions.
    static func netDoses(_ input: BasalTestInput, from: Date, to: Date, calendar: Calendar) -> [InsulinDose] {
        var doses = input.boluses
            .filter { $0.date >= from && $0.date < to }
            .map { InsulinDose(date: $0.date, units: $0.units) }

        let tempBasals = input.tempBasals.sorted { $0.start < $1.start }
        let schedule = input.basalSchedule.sorted { $0.startMinute < $1.startMinute }
        guard !schedule.isEmpty else { return doses.sorted { $0.date < $1.date } }

        var cursor = from
        while cursor < to {
            let end = min(cursor.addingTimeInterval(stepMinutes * 60), to)
            let span = BasalTestSpan(start: cursor, end: end)
            let middle = cursor.addingTimeInterval(end.timeIntervalSince(cursor) / 2)
            let delivered = BasalTestEvaluator.deliveredBasal(
                in: span,
                tempBasals: tempBasals,
                suspensions: input.suspensions,
                schedule: schedule,
                calendar: calendar
            )
            let scheduled = (BasalTestEvaluator.scheduleValue(at: middle, schedule: schedule, calendar: calendar) ?? 0)
                * span.minutes / 60
            let net = delivered - scheduled
            if abs(net) > 0.000_001 {
                doses.append(InsulinDose(date: middle, units: net))
            }
            cursor = end
        }
        return doses.sorted { $0.date < $1.date }
    }

    /// Units of the given doses that were absorbed inside a span. `doses` must be sorted by date.
    static func absorbed(_ doses: [InsulinDose], in span: BasalTestSpan, model: InsulinActionModel) -> Double {
        let earliest = span.start.addingTimeInterval(-max(model.durationMinutes, 180) * 60)

        // First dose that can still be active.
        var low = 0
        var high = doses.count
        while low < high {
            let middle = (low + high) / 2
            if doses[middle].date <= earliest {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var total = 0.0
        var index = low
        while index < doses.count, doses[index].date < span.end {
            let dose = doses[index]
            let ageAtStart = span.start.timeIntervalSince(dose.date) / 60
            let ageAtEnd = span.end.timeIntervalSince(dose.date) / 60
            total += dose.units * (model.remaining(after: ageAtStart) - model.remaining(after: ageAtEnd))
            index += 1
        }
        return total
    }
}

// MARK: - Basal need

enum BasalNeedEstimator {
    /// The basal rate that would have kept glucose level in a fasting window, in U/hr.
    ///
    /// The basal check adds up the insulin delivered inside the window. That is good enough for a
    /// suggestion a person looks at, but insulin keeps acting for hours: after a correction the
    /// loop delivers little while the earlier insulin still pulls glucose down, and the window
    /// seems to need less than it does. The learner therefore counts the insulin that was
    /// absorbed in the window, whenever it was delivered:
    /// `need = scheduled + net insulin absorbed per hour + glucose drift / ISF`.
    static func need(
        in window: BasalTestWindow,
        scheduledRate: Double,
        doses: [InsulinDose],
        model: InsulinActionModel
    ) -> Double? {
        let span = BasalTestSpan(start: window.start, end: window.end)
        let hours = span.minutes / 60
        guard hours > 0, window.sensitivity > 0 else { return nil }
        let absorbed = InsulinAccounting.absorbed(doses, in: span, model: model)
        return max(0, scheduledRate + absorbed / hours + window.glucoseSlopePerHour / window.sensitivity)
    }

    /// Whether glucose moved as slowly as a basal rate can move it. A wrong basal rate makes
    /// glucose drift; a jump within a quarter of an hour is food nobody entered, a sensor
    /// artefact or a sensor change, and none of those says anything about basal.
    /// `glucose` must be sorted by date.
    static func isSmooth(
        _ glucose: [BasalTestGlucose],
        from start: Date,
        to end: Date,
        maxChangePerQuarterHour: Double = 20
    ) -> Bool {
        let readings = glucose.filter { $0.date >= start && $0.date <= end }
        var earlier = 0
        for (index, reading) in readings.enumerated() {
            while reading.date.timeIntervalSince(readings[earlier].date) > 16 * 60 {
                earlier += 1
            }
            for other in readings[earlier ..< index] where abs(reading.value - other.value) > maxChangePerQuarterHour {
                return false
            }
        }
        return true
    }
}

// MARK: - Samples

/// One observation of what a setting should have been, at a time of day.
struct SettingSample: Equatable {
    let date: Date
    /// The time block of the schedule the observation belongs to, in minutes after midnight.
    let blockStartMinute: Int
    let value: Double
}

struct SensitivityConfig: Equatable {
    /// Time after carbs before a correction is looked at.
    var carbClearHours: Double = 5
    /// A correction is only evaluated from this glucose value upwards (mg/dL).
    var correctionStartGlucose: Double = 140
    var correctionMinutes: Double = 150
    /// A correction that is cut short, for example by a low, still counts from this length on.
    var correctionMinMinutes: Double = 90
    /// Smaller drops are too close to sensor noise (mg/dL).
    var correctionMinDrop: Double = 15
    /// Less insulin than this makes the quotient unreliable.
    var minInsulinUnits: Double = 0.3
    var mealMinCarbs: Double = 15
    /// Entries this close together count as one meal.
    var mealGroupMinutes: Double = 30
    /// No other carbs this long before a meal.
    var mealClearBeforeMinutes: Double = 180
    var mealWindowMinutes: Double = 240
    /// A meal that ends in a low is evaluated up to the low, if the low comes this late.
    var mealMinMinutesBeforeLow: Double = 120
    /// Observations further than this factor from the current setting are discarded as outliers.
    var plausibleFactor: Double = 3
    /// Readings within this time are averaged for the start and end value.
    var edgeMinutes: Double = 10
}

/// Estimates insulin sensitivity and carb ratio from history.
///
/// Both need to know how much of the insulin was used up by the basal need. `basalOffset` tells
/// them how far the estimated need lies above the scheduled rate at a given time, in U/hr. With
/// the default of zero they take the schedule as correct, and an error in it shows up as an
/// error in sensitivity or carb ratio. The learner passes its own basal estimate and corrects
/// basal first.
enum SensitivityEstimator {
    // MARK: Insulin sensitivity

    /// Corrections without food: how far glucose fell per unit of insulin absorbed.
    static func sensitivitySamples(
        _ input: BasalTestInput,
        doses: [InsulinDose],
        model: InsulinActionModel,
        config: SensitivityConfig = SensitivityConfig(),
        base: BasalTestConfig = BasalTestConfig(),
        calendar: Calendar,
        basalOffset: (Date) -> Double = { _ in 0 }
    ) -> [SettingSample] {
        let glucose = input.glucose.sorted { $0.date < $1.date }
        guard let first = glucose.first, let last = glucose.last, first.date < last.date else { return [] }

        // Boluses are the signal here, so they do not disqualify anything.
        var withoutBoluses = input
        withoutBoluses.boluses = []
        var exclusionConfig = base
        exclusionConfig.carbLeadHours = config.carbClearHours
        let clean = BasalTestEvaluator.subtract(
            BasalTestEvaluator.exclusions(withoutBoluses, glucose: glucose, config: exclusionConfig),
            from: BasalTestSpan(start: first.date, end: last.date)
        )

        var samples: [SettingSample] = []
        for span in clean where span.minutes >= config.correctionMinMinutes {
            let readings = glucose.filter { $0.date >= span.start && $0.date <= span.end }
            var index = 0
            while index < readings.count {
                let start = readings[index]
                var end = start.date.addingTimeInterval(config.correctionMinutes * 60)
                if end > span.end {
                    // Use what there is. A span often ends because glucose went low, and those
                    // are the corrections that say most about a sensitivity that is set too low.
                    guard span.end.timeIntervalSince(start.date) >= config.correctionMinMinutes * 60 else { break }
                    end = span.end
                }

                guard start.value >= config.correctionStartGlucose,
                      let sample = correctionSample(
                          from: start.date,
                          to: end,
                          readings: readings,
                          input: input,
                          doses: doses,
                          model: model,
                          config: config,
                          calendar: calendar,
                          basalOffset: basalOffset(start.date)
                      )
                else {
                    index += 1
                    continue
                }
                samples.append(sample)
                // Episodes do not overlap.
                index = readings.firstIndex(where: { $0.date >= end }) ?? readings.count
            }
        }
        return samples
    }

    private static func correctionSample(
        from start: Date,
        to end: Date,
        readings: [BasalTestGlucose],
        input: BasalTestInput,
        doses: [InsulinDose],
        model: InsulinActionModel,
        config: SensitivityConfig,
        calendar: Calendar,
        basalOffset: Double
    ) -> SettingSample? {
        let edge = config.edgeMinutes * 60
        guard let startValue = mean(readings, from: start, to: start.addingTimeInterval(edge)),
              let endValue = mean(readings, from: end.addingTimeInterval(-edge), to: end)
        else { return nil }

        // The averaged values stand for the middle of their edge, so the insulin is counted
        // between those two moments. Counting the whole span would make insulin look weaker.
        let measured = BasalTestSpan(start: start.addingTimeInterval(edge / 2), end: end.addingTimeInterval(-edge / 2))
        let drop = startValue - endValue
        // Only insulin beyond the basal need lowers glucose.
        let absorbed = InsulinAccounting.absorbed(doses, in: measured, model: model) - basalOffset * measured.minutes / 60
        guard drop >= config.correctionMinDrop, absorbed >= config.minInsulinUnits else { return nil }

        let observed = drop / absorbed
        guard let current = BasalTestEvaluator.scheduleValue(at: start, schedule: input.sensitivitySchedule, calendar: calendar),
              isPlausible(observed, comparedTo: current, factor: config.plausibleFactor)
        else { return nil }

        return SettingSample(
            date: start,
            blockStartMinute: blockStart(at: start, schedule: input.sensitivitySchedule, calendar: calendar),
            value: observed
        )
    }

    // MARK: Carb ratio

    /// Isolated meals: the carbs divided by the insulin that would have brought glucose back to
    /// where it started by the end of the meal window.
    static func carbRatioSamples(
        _ input: BasalTestInput,
        doses: [InsulinDose],
        model: InsulinActionModel,
        config: SensitivityConfig = SensitivityConfig(),
        base: BasalTestConfig = BasalTestConfig(),
        calendar: Calendar,
        basalOffset: (Date) -> Double = { _ in 0 }
    ) -> [SettingSample] {
        let glucose = input.glucose.sorted { $0.date < $1.date }
        guard let lastReading = glucose.last else { return [] }

        // Carbs and boluses belong to a meal. Adjustments and sensor gaps spoil it. Lows are
        // looked at separately below.
        var disturbancesOnly = input
        disturbancesOnly.boluses = []
        disturbancesOnly.carbDates = []
        var disturbanceConfig = base
        disturbanceConfig.lowGlucoseThreshold = -.infinity
        let disturbances = BasalTestEvaluator.exclusions(disturbancesOnly, glucose: glucose, config: disturbanceConfig)

        let carbs = input.carbs.filter { $0.grams > 0 }.sorted { $0.date < $1.date }
        let everythingEaten = input.carbDates.sorted()

        var samples: [SettingSample] = []
        var index = 0
        while index < carbs.count {
            let mealStart = carbs[index].date
            let groupEnd = mealStart.addingTimeInterval(config.mealGroupMinutes * 60)
            var grams = 0.0
            var next = index
            while next < carbs.count, carbs[next].date <= groupEnd {
                grams += carbs[next].grams
                next += 1
            }
            index = next

            let fullEnd = mealStart.addingTimeInterval(config.mealWindowMinutes * 60)
            let clearFrom = mealStart.addingTimeInterval(-config.mealClearBeforeMinutes * 60)
            guard grams >= config.mealMinCarbs, fullEnd <= lastReading.date else { continue }

            // A low before the meal means a rebound, and usually carbs nobody entered.
            let lows = glucose.filter { $0.value < base.lowGlucoseThreshold && $0.date >= clearFrom && $0.date <= fullEnd }
            guard !lows.contains(where: { $0.date < mealStart }) else { continue }

            // A low after the meal ends the evaluation there: from then on rescue carbs distort
            // the picture. Up to the low the meal still shows that it got too much insulin.
            var windowEnd = fullEnd
            if let low = lows.first {
                guard low.date.timeIntervalSince(mealStart) >= config.mealMinMinutesBeforeLow * 60 else { continue }
                windowEnd = low.date
            }

            let hasOtherFood = everythingEaten.contains { date in
                (date >= clearFrom && date < mealStart) || (date > groupEnd && date <= windowEnd)
            }
            let isDisturbed = disturbances.contains { $0.start < windowEnd && $0.end > mealStart }
            guard !hasOtherFood, !isDisturbed else { continue }

            let edge = config.edgeMinutes * 60
            guard let startValue = mean(glucose, from: mealStart.addingTimeInterval(-edge), to: mealStart),
                  let endValue = mean(glucose, from: windowEnd.addingTimeInterval(-edge), to: windowEnd),
                  let sensitivity = BasalTestEvaluator.scheduleValue(
                      at: mealStart,
                      schedule: input.sensitivitySchedule,
                      calendar: calendar
                  ), sensitivity > 0,
                  let current = BasalTestEvaluator.scheduleValue(
                      at: mealStart,
                      schedule: input.carbRatioSchedule,
                      calendar: calendar
                  )
            else { continue }

            // Between the moments the two averaged glucose values stand for, and without the
            // part the basal need used up.
            let measured = BasalTestSpan(
                start: mealStart.addingTimeInterval(-edge / 2),
                end: windowEnd.addingTimeInterval(-edge / 2)
            )
            let absorbed = InsulinAccounting.absorbed(doses, in: measured, model: model)
                - basalOffset(mealStart) * measured.minutes / 60
            // Glucose that ended higher than it started stands for insulin that was missing.
            let needed = absorbed + (endValue - startValue) / sensitivity
            guard needed >= config.minInsulinUnits else { continue }

            let observed = grams / needed
            guard isPlausible(observed, comparedTo: current, factor: config.plausibleFactor) else { continue }

            samples.append(
                SettingSample(
                    date: mealStart,
                    blockStartMinute: blockStart(at: mealStart, schedule: input.carbRatioSchedule, calendar: calendar),
                    value: observed
                )
            )
        }
        return samples
    }

    // MARK: Helpers

    static func blockStart(at date: Date, schedule: [BasalTestScheduleEntry], calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let sorted = schedule.sorted { $0.startMinute < $1.startMinute }
        return (sorted.last(where: { $0.startMinute <= minute }) ?? sorted.first)?.startMinute ?? 0
    }

    private static func mean(_ readings: [BasalTestGlucose], from: Date, to: Date) -> Double? {
        let values = readings.filter { $0.date >= from && $0.date <= to }.map(\.value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func isPlausible(_ observed: Double, comparedTo current: Double, factor: Double) -> Bool {
        guard current > 0, observed > 0, factor > 1 else { return false }
        return observed >= current / factor && observed <= current * factor
    }
}
