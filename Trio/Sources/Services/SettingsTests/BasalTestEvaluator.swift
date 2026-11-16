import Foundation

// MARK: - Configuration

/// Thresholds of the retrospective basal check. The defaults are deliberately cautious.
struct BasalTestConfig: Equatable {
    /// Time after carbs during which glucose is not considered fasting.
    var carbLeadHours: Double = 4
    /// Time after a manual bolus during which glucose is not considered undisturbed.
    var bolusLeadHours: Double = 4
    /// Time after an override or temp target ended before data counts again.
    var adjustmentLeadMinutes: Double = 60
    /// Readings below this value, and the hours after them, are left out (treatment, rebound).
    var lowGlucoseThreshold: Double = 70
    var lowLeadHours: Double = 3
    /// Two readings further apart than this split a window.
    var maxGlucoseGapMinutes: Double = 15
    var minWindowMinutes: Double = 60
    var minGlucoseSamples: Int = 6
    /// A window drifting faster than this (mg/dL per hour) is treated as disturbed, for example by
    /// carbs that were not entered.
    var maxAbsSlopePerHour: Double = 30
    /// Number of usable windows a time block needs before anything is suggested.
    var minWindows: Int = 3
    /// Share of windows that must point in the same direction.
    var agreementFraction: Double = 0.75
    /// Differences below this share of the scheduled rate count as a match.
    var deadbandFraction: Double = 0.05
    /// Largest change of a single suggestion, as a share of the scheduled rate.
    var maxStepFraction: Double = 0.10
}

// MARK: - Input

struct BasalTestGlucose: Equatable {
    let date: Date
    /// mg/dL
    let value: Double
}

struct BasalTestBolus: Equatable {
    let date: Date
    let units: Double
    /// `true` for boluses the loop gave on its own (SMB).
    let isAutomatic: Bool
}

struct BasalTestTempBasal: Equatable {
    let start: Date
    let durationMinutes: Double
    /// U/hr
    let rate: Double
    /// A marker that the pump returned to its schedule; it covers no time by itself.
    let isScheduledBasal: Bool
}

struct BasalTestCarb: Equatable {
    let date: Date
    let grams: Double
}

struct BasalTestSpan: Equatable {
    let start: Date
    let end: Date

    var minutes: Double { end.timeIntervalSince(start) / 60 }
}

struct BasalTestScheduleEntry: Equatable {
    /// Minutes after midnight.
    let startMinute: Int
    let value: Double
}

struct BasalTestInput {
    var glucose: [BasalTestGlucose] = []
    var carbDates: [Date] = []
    var boluses: [BasalTestBolus] = []
    var tempBasals: [BasalTestTempBasal] = []
    var suspensions: [BasalTestSpan] = []
    /// Times during which an override or temp target was active.
    var adjustments: [BasalTestSpan] = []
    var basalSchedule: [BasalTestScheduleEntry] = []
    /// mg/dL per unit
    var sensitivitySchedule: [BasalTestScheduleEntry] = []
    /// Carb entries with their amounts, without fat and protein equivalents. Used by the
    /// settings learner; `carbDates` stays the complete list of everything that was eaten.
    var carbs: [BasalTestCarb] = []
    /// Grams per unit. Used by the settings learner.
    var carbRatioSchedule: [BasalTestScheduleEntry] = []
}

// MARK: - Output

/// One undisturbed stretch of data inside a single basal time block.
struct BasalTestWindow: Equatable {
    let start: Date
    let end: Date
    let blockStartMinute: Int
    /// mg/dL per hour
    let glucoseSlopePerHour: Double
    /// Insulin actually delivered (basal plus automatic boluses), U/hr.
    let deliveredRate: Double
    let sensitivity: Double
    /// The rate that would have kept glucose level, U/hr.
    let estimatedNeed: Double
}

enum BasalTestVerdict: Equatable {
    case notEnoughData
    /// The windows do not agree on a direction.
    case inconclusive
    case matches
    case raise
    case lower
}

struct BasalBlockResult: Identifiable, Equatable {
    let blockStartMinute: Int
    let blockEndMinute: Int
    let scheduledRate: Double
    let windows: [BasalTestWindow]
    let medianNeed: Double?
    let verdict: BasalTestVerdict
    let proposedRate: Double?

    var id: Int { blockStartMinute }
}

// MARK: - Evaluation

/// Looks back over glucose and insulin history, finds stretches without food, manual boluses or
/// adjustments, and estimates from them how much basal insulin each time block needed.
///
/// Under closed loop a wrong basal rate hardly shows in glucose, because the loop compensates.
/// The estimate therefore starts from the insulin that was actually delivered and corrects it by
/// the remaining glucose drift: `need = delivered + drift / ISF`.
///
/// Pure arithmetic over value types: no storage, no clock, no randomness.
enum BasalTestEvaluator {
    static func evaluate(
        _ input: BasalTestInput,
        config: BasalTestConfig = BasalTestConfig(),
        supportedBasalRates: [Double]? = nil,
        calendar: Calendar = .current
    ) -> [BasalBlockResult] {
        let schedule = input.basalSchedule.sorted { $0.startMinute < $1.startMinute }
        guard !schedule.isEmpty else { return [] }

        let allWindows = windows(input, config: config, calendar: calendar)

        return schedule.enumerated().map { index, entry in
            let blockEnd = index + 1 < schedule.count ? schedule[index + 1].startMinute : 24 * 60
            let blockWindows = allWindows.filter { $0.blockStartMinute == entry.startMinute }
            return summarize(
                blockStartMinute: entry.startMinute,
                blockEndMinute: blockEnd,
                scheduledRate: entry.value,
                windows: blockWindows,
                config: config,
                supportedBasalRates: supportedBasalRates
            )
        }
    }

    // MARK: Windows

    static func windows(
        _ input: BasalTestInput,
        config: BasalTestConfig,
        calendar: Calendar
    ) -> [BasalTestWindow] {
        let glucose = input.glucose.sorted { $0.date < $1.date }
        let schedule = input.basalSchedule.sorted { $0.startMinute < $1.startMinute }
        guard let first = glucose.first, let last = glucose.last, first.date < last.date, !schedule.isEmpty else {
            return []
        }

        let tempBasals = input.tempBasals.sorted { $0.start < $1.start }
        let clean = subtract(
            exclusions(input, glucose: glucose, config: config),
            from: BasalTestSpan(start: first.date, end: last.date)
        )

        var result: [BasalTestWindow] = []
        for span in clean {
            var cursor = span.start
            while cursor < span.end {
                let block = blockBounds(at: cursor, schedule: schedule, calendar: calendar)
                // Always move forward, also on days with a clock change.
                let pieceEnd = max(min(span.end, block.end), cursor.addingTimeInterval(60))
                let piece = BasalTestSpan(start: cursor, end: min(pieceEnd, span.end))
                cursor = pieceEnd

                guard piece.minutes >= config.minWindowMinutes else { continue }
                if let window = evaluateWindow(
                    piece,
                    blockStartMinute: block.startMinute,
                    glucose: glucose,
                    boluses: input.boluses,
                    tempBasals: tempBasals,
                    suspensions: input.suspensions,
                    schedule: schedule,
                    sensitivities: input.sensitivitySchedule,
                    config: config,
                    calendar: calendar
                ) {
                    result.append(window)
                }
            }
        }
        return result
    }

    /// Everything that disqualifies data from a fasting test.
    static func exclusions(
        _ input: BasalTestInput,
        glucose: [BasalTestGlucose],
        config: BasalTestConfig
    ) -> [BasalTestSpan] {
        var spans: [BasalTestSpan] = []

        for date in input.carbDates {
            spans.append(BasalTestSpan(start: date, end: date.addingTimeInterval(config.carbLeadHours * 3600)))
        }
        for bolus in input.boluses where !bolus.isAutomatic {
            spans.append(BasalTestSpan(start: bolus.date, end: bolus.date.addingTimeInterval(config.bolusLeadHours * 3600)))
        }
        for adjustment in input.adjustments {
            spans.append(
                BasalTestSpan(
                    start: adjustment.start,
                    end: adjustment.end.addingTimeInterval(config.adjustmentLeadMinutes * 60)
                )
            )
        }
        for reading in glucose where reading.value < config.lowGlucoseThreshold {
            spans.append(
                BasalTestSpan(
                    start: reading.date.addingTimeInterval(-30 * 60),
                    end: reading.date.addingTimeInterval(config.lowLeadHours * 3600)
                )
            )
        }
        for (previous, next) in zip(glucose, glucose.dropFirst())
            where next.date.timeIntervalSince(previous.date) > config.maxGlucoseGapMinutes * 60
        {
            spans.append(BasalTestSpan(start: previous.date, end: next.date))
        }

        return merged(spans)
    }

    static func merged(_ spans: [BasalTestSpan]) -> [BasalTestSpan] {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result: [BasalTestSpan] = []
        for span in sorted {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1] = BasalTestSpan(start: last.start, end: max(last.end, span.end))
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// The parts of `range` that no exclusion touches. `exclusions` must be merged and sorted.
    static func subtract(_ exclusions: [BasalTestSpan], from range: BasalTestSpan) -> [BasalTestSpan] {
        var result: [BasalTestSpan] = []
        var cursor = range.start
        for exclusion in exclusions {
            if exclusion.end <= cursor { continue }
            if exclusion.start >= range.end { break }
            if exclusion.start > cursor {
                result.append(BasalTestSpan(start: cursor, end: min(exclusion.start, range.end)))
            }
            cursor = max(cursor, exclusion.end)
        }
        if cursor < range.end {
            result.append(BasalTestSpan(start: cursor, end: range.end))
        }
        return result
    }

    // MARK: One window

    private static func evaluateWindow(
        _ span: BasalTestSpan,
        blockStartMinute: Int,
        glucose: [BasalTestGlucose],
        boluses: [BasalTestBolus],
        tempBasals: [BasalTestTempBasal],
        suspensions: [BasalTestSpan],
        schedule: [BasalTestScheduleEntry],
        sensitivities: [BasalTestScheduleEntry],
        config: BasalTestConfig,
        calendar: Calendar
    ) -> BasalTestWindow? {
        let readings = glucose.filter { $0.date >= span.start && $0.date <= span.end }
        guard readings.count >= config.minGlucoseSamples,
              let slope = slopePerHour(readings),
              abs(slope) <= config.maxAbsSlopePerHour
        else { return nil }

        let middle = span.start.addingTimeInterval(span.end.timeIntervalSince(span.start) / 2)
        guard let sensitivity = scheduleValue(at: middle, schedule: sensitivities, calendar: calendar), sensitivity > 0 else {
            return nil
        }

        let hours = span.minutes / 60
        guard hours > 0 else { return nil }

        let basalUnits = deliveredBasal(
            in: span,
            tempBasals: tempBasals,
            suspensions: suspensions,
            schedule: schedule,
            calendar: calendar
        )
        let automaticUnits = boluses
            .filter { $0.isAutomatic && $0.date >= span.start && $0.date < span.end }
            .reduce(0) { $0 + $1.units }
        let deliveredRate = (basalUnits + automaticUnits) / hours

        return BasalTestWindow(
            start: span.start,
            end: span.end,
            blockStartMinute: blockStartMinute,
            glucoseSlopePerHour: slope,
            deliveredRate: deliveredRate,
            sensitivity: sensitivity,
            estimatedNeed: max(0, deliveredRate + slope / sensitivity)
        )
    }

    /// Least-squares slope of glucose over time, in mg/dL per hour.
    static func slopePerHour(_ readings: [BasalTestGlucose]) -> Double? {
        guard let first = readings.first, readings.count >= 2 else { return nil }
        let xs = readings.map { $0.date.timeIntervalSince(first.date) / 3600 }
        let ys = readings.map(\.value)
        let count = Double(readings.count)
        let meanX = xs.reduce(0, +) / count
        let meanY = ys.reduce(0, +) / count
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    /// Basal insulin delivered in a span, in units: temp basals where they ran, the schedule in
    /// between, nothing while the pump was suspended.
    static func deliveredBasal(
        in span: BasalTestSpan,
        tempBasals: [BasalTestTempBasal],
        suspensions: [BasalTestSpan],
        schedule: [BasalTestScheduleEntry],
        calendar: Calendar
    ) -> Double {
        var total = 0.0
        var cursor = span.start
        while cursor < span.end {
            let step = min(60, span.end.timeIntervalSince(cursor))
            let middle = cursor.addingTimeInterval(step / 2)
            if !suspensions.contains(where: { $0.start <= middle && middle < $0.end }) {
                let rate = tempBasalRate(at: middle, tempBasals: tempBasals)
                    ?? scheduleValue(at: middle, schedule: schedule, calendar: calendar)
                    ?? 0
                total += rate * step / 3600
            }
            cursor = cursor.addingTimeInterval(step)
        }
        return total
    }

    /// The temp basal in effect at a moment, or `nil` when the schedule applies.
    /// `tempBasals` must be sorted by start.
    private static func tempBasalRate(at date: Date, tempBasals: [BasalTestTempBasal]) -> Double? {
        var low = 0
        var high = tempBasals.count
        while low < high {
            let middle = (low + high) / 2
            if tempBasals[middle].start <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0 else { return nil }
        let latest = tempBasals[low - 1]
        guard !latest.isScheduledBasal,
              date < latest.start.addingTimeInterval(latest.durationMinutes * 60)
        else { return nil }
        return latest.rate
    }

    // MARK: Schedules

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    static func scheduleValue(at date: Date, schedule: [BasalTestScheduleEntry], calendar: Calendar) -> Double? {
        let minute = minuteOfDay(date, calendar: calendar)
        let sorted = schedule.sorted { $0.startMinute < $1.startMinute }
        return (sorted.last(where: { $0.startMinute <= minute }) ?? sorted.first)?.value
    }

    /// The basal time block a moment falls into, and the moment that block ends.
    private static func blockBounds(
        at date: Date,
        schedule: [BasalTestScheduleEntry],
        calendar: Calendar
    ) -> (startMinute: Int, end: Date) {
        let minute = minuteOfDay(date, calendar: calendar)
        let index = schedule.lastIndex(where: { $0.startMinute <= minute }) ?? 0
        let endMinute = index + 1 < schedule.count ? schedule[index + 1].startMinute : 24 * 60
        let dayStart = calendar.startOfDay(for: date)
        return (schedule[index].startMinute, dayStart.addingTimeInterval(Double(endMinute) * 60))
    }

    // MARK: Summary and suggestion

    static func summarize(
        blockStartMinute: Int,
        blockEndMinute: Int,
        scheduledRate: Double,
        windows: [BasalTestWindow],
        config: BasalTestConfig,
        supportedBasalRates: [Double]?
    ) -> BasalBlockResult {
        func result(_ verdict: BasalTestVerdict, median: Double?, proposed: Double? = nil) -> BasalBlockResult {
            BasalBlockResult(
                blockStartMinute: blockStartMinute,
                blockEndMinute: blockEndMinute,
                scheduledRate: scheduledRate,
                windows: windows,
                medianNeed: median,
                verdict: verdict,
                proposedRate: proposed
            )
        }

        let needs = windows.map(\.estimatedNeed).sorted()
        guard !needs.isEmpty else { return result(.notEnoughData, median: nil) }

        let median = needs.count % 2 == 1
            ? needs[needs.count / 2]
            : (needs[needs.count / 2 - 1] + needs[needs.count / 2]) / 2

        guard needs.count >= config.minWindows, scheduledRate > 0 else {
            return result(.notEnoughData, median: median)
        }

        let difference = median - scheduledRate
        guard abs(difference) >= scheduledRate * config.deadbandFraction else {
            return result(.matches, median: median)
        }

        let agreeing = needs.filter { ($0 - scheduledRate) * difference > 0 }.count
        guard Double(agreeing) / Double(needs.count) >= config.agreementFraction else {
            return result(.inconclusive, median: median)
        }

        guard let proposed = proposedRate(
            scheduledRate: scheduledRate,
            need: median,
            maxStepFraction: config.maxStepFraction,
            supportedBasalRates: supportedBasalRates
        ) else {
            // The pump cannot express a change this small.
            return result(.matches, median: median)
        }

        return result(proposed > scheduledRate ? .raise : .lower, median: median, proposed: proposed)
    }

    /// A small step from the scheduled rate towards the estimated need, on a rate the pump supports.
    /// Returns `nil` when no supported rate lies in that direction close enough to be justified.
    static func proposedRate(
        scheduledRate: Double,
        need: Double,
        maxStepFraction: Double,
        supportedBasalRates: [Double]?
    ) -> Double? {
        let tolerance = 0.0005
        let rates = (supportedBasalRates ?? defaultRates).filter { $0 > 0 }.sorted()
        guard !rates.isEmpty, scheduledRate > 0 else { return nil }

        let lowerLimit = scheduledRate * (1 - maxStepFraction)
        let upperLimit = scheduledRate * (1 + maxStepFraction)
        let target = min(max(need, lowerLimit), upperLimit)

        if let nearest = rates.min(by: { abs($0 - target) < abs($1 - target) }),
           abs(nearest - scheduledRate) > tolerance,
           (nearest - scheduledRate) * (need - scheduledRate) > 0
        {
            return nearest
        }

        // The capped step is smaller than the pump's increment. Take one increment if the
        // estimate is at least half an increment away.
        let neighbour = need > scheduledRate
            ? rates.first(where: { $0 > scheduledRate + tolerance })
            : rates.last(where: { $0 < scheduledRate - tolerance })
        guard let neighbour, abs(need - scheduledRate) >= abs(neighbour - scheduledRate) / 2 else { return nil }
        return neighbour
    }

    /// 0.05 U/hr steps up to 10 U/hr, the fallback the basal editor uses without a pump.
    private static let defaultRates: [Double] = (1 ... 200).map { Double($0) * 5 / 100 }
}
