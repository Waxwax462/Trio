import Foundation
import Testing

@testable import Trio

@Suite("Basal Test Evaluator Tests") struct BasalTestEvaluatorTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Midnight UTC.
    private let dayZero = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400))

    private func time(day: Int, minutes: Double) -> Date {
        dayZero.addingTimeInterval(Double(day) * 86400 + minutes * 60)
    }

    /// Readings every five minutes from 00:00 to 06:00 on each of the given nights.
    private func nights(_ count: Int, startValue: Double = 110, slopePerHour: Double = 0) -> [BasalTestGlucose] {
        (0 ..< count).flatMap { day in
            stride(from: 0.0, through: 360.0, by: 5.0).map { minute in
                BasalTestGlucose(date: time(day: day, minutes: minute), value: startValue + slopePerHour * minute / 60)
            }
        }
    }

    private func makeInput(
        glucose: [BasalTestGlucose],
        basal: [(Int, Double)] = [(0, 1.0)],
        sensitivity: Double = 50
    ) -> BasalTestInput {
        var input = BasalTestInput()
        input.glucose = glucose
        input.basalSchedule = basal.map { BasalTestScheduleEntry(startMinute: $0.0, value: $0.1) }
        input.sensitivitySchedule = [BasalTestScheduleEntry(startMinute: 0, value: sensitivity)]
        return input
    }

    private func evaluate(_ input: BasalTestInput, config: BasalTestConfig = BasalTestConfig()) -> [BasalBlockResult] {
        BasalTestEvaluator.evaluate(input, config: config, supportedBasalRates: nil, calendar: calendar)
    }

    private func isClose(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.01) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < tolerance
    }

    // MARK: - Verdicts

    @Test("Flat glucose with scheduled delivery matches") func testStableNights() throws {
        let results = evaluate(makeInput(glucose: nights(4)))

        let block = try #require(results.first)
        #expect(results.count == 1)
        #expect(block.windows.count == 4)
        #expect(isClose(block.medianNeed, 1.0))
        #expect(block.verdict == .matches)
        #expect(block.proposedRate == nil)
    }

    @Test("A steady rise at scheduled delivery suggests more basal, in a capped step") func testRisingNights() throws {
        // +10 mg/dL per hour at ISF 50 is 0.2 U/hr missing; the step is capped at 10 %.
        let results = evaluate(makeInput(glucose: nights(4, slopePerHour: 10)))

        let block = try #require(results.first)
        #expect(isClose(block.medianNeed, 1.2))
        #expect(block.verdict == .raise)
        #expect(isClose(block.proposedRate, 1.1))
    }

    @Test("Flat glucose while the loop delivered less suggests less basal") func testLoopCompensatedDown() throws {
        var input = makeInput(glucose: nights(4))
        input.tempBasals = (0 ..< 4).map {
            BasalTestTempBasal(start: time(day: $0, minutes: 0), durationMinutes: 360, rate: 0.7, isScheduledBasal: false)
        }

        let block = try #require(evaluate(input).first)

        #expect(isClose(block.windows.first?.deliveredRate, 0.7))
        #expect(isClose(block.medianNeed, 0.7))
        #expect(block.verdict == .lower)
        #expect(isClose(block.proposedRate, 0.9))
    }

    @Test("Automatic boluses count as delivered insulin") func testAutomaticBolusesCount() throws {
        var input = makeInput(glucose: nights(4))
        // 0.6 U of SMBs over six hours adds 0.1 U/hr to the scheduled 1.0.
        input.boluses = (0 ..< 4).flatMap { day in
            [60.0, 120.0, 180.0].map { BasalTestBolus(date: time(day: day, minutes: $0), units: 0.2, isAutomatic: true) }
        }

        let block = try #require(evaluate(input).first)

        #expect(block.windows.count == 4, "Automatic boluses do not disqualify a window")
        #expect(isClose(block.medianNeed, 1.1))
        #expect(block.verdict == .raise)
    }

    @Test("Fewer windows than required give no suggestion") func testNotEnoughWindows() throws {
        let block = try #require(evaluate(makeInput(glucose: nights(2, slopePerHour: 10))).first)

        #expect(block.windows.count == 2)
        #expect(block.verdict == .notEnoughData)
        #expect(block.proposedRate == nil)
    }

    @Test("Windows that disagree give no suggestion") func testInconclusive() throws {
        let rising = nights(2, slopePerHour: 12)
        let falling = nights(4, slopePerHour: -12).filter { $0.date >= time(day: 2, minutes: 0) }

        let block = try #require(evaluate(makeInput(glucose: rising + falling)).first)

        #expect(block.windows.count == 4)
        #expect(block.verdict != .raise)
        #expect(block.verdict != .lower)
        #expect(block.proposedRate == nil)
    }

    // MARK: - Exclusions

    @Test("Carbs, manual boluses and adjustments disqualify the hours after them") func testExclusions() throws {
        var withCarbs = makeInput(glucose: nights(4, slopePerHour: 10))
        withCarbs.carbDates = (0 ..< 4).map { time(day: $0, minutes: 150) }
        // 02:30 + 4 h covers the rest of the night; 00:00–02:30 remains.
        let carbBlock = try #require(evaluate(withCarbs).first)
        #expect(carbBlock.windows.allSatisfy { $0.end <= time(day: 3, minutes: 150) })
        #expect(carbBlock.windows.allSatisfy { $0.end.timeIntervalSince($0.start) <= 150 * 60 })

        var withBolus = makeInput(glucose: nights(4, slopePerHour: 10))
        withBolus.boluses = (0 ..< 4).map { BasalTestBolus(date: time(day: $0, minutes: -30), units: 2, isAutomatic: false) }
        // 23:30 the evening before + 4 h leaves 03:30–06:00.
        let bolusBlock = try #require(evaluate(withBolus).first)
        #expect(bolusBlock.windows.count == 4)
        #expect(bolusBlock.windows.allSatisfy { calendar.component(.hour, from: $0.start) == 3 })

        var withOverride = makeInput(glucose: nights(4, slopePerHour: 10))
        withOverride.adjustments = (0 ..< 4).map { BasalTestSpan(start: time(day: $0, minutes: -60), end: time(day: $0, minutes: 400)) }
        let overrideBlock = try #require(evaluate(withOverride).first)
        #expect(overrideBlock.windows.isEmpty)
        #expect(overrideBlock.verdict == .notEnoughData)
    }

    @Test("A low reading disqualifies the hours around it") func testLowGlucoseExcluded() throws {
        var glucose = nights(4)
        // One low at 03:00 on every night.
        glucose = glucose.map { reading in
            calendar.component(.hour, from: reading.date) == 3 && calendar.component(.minute, from: reading.date) == 0
                ? BasalTestGlucose(date: reading.date, value: 60)
                : reading
        }

        let block = try #require(evaluate(makeInput(glucose: glucose)).first)

        // 02:30–06:00 is out, 00:00–02:30 stays.
        #expect(block.windows.count == 4)
        #expect(block.windows.allSatisfy { $0.end <= $0.start.addingTimeInterval(150 * 60) })
    }

    @Test("A gap in the readings splits the window") func testGlucoseGap() throws {
        let glucose = nights(4).filter { reading in
            let hour = calendar.component(.hour, from: reading.date)
            return hour != 2
        }

        let block = try #require(evaluate(makeInput(glucose: glucose)).first)

        // 00:00–01:55 and 03:00–06:00 on each night.
        #expect(block.windows.count == 8)
    }

    @Test("A window drifting too fast is treated as disturbed") func testFastDriftExcluded() throws {
        let block = try #require(evaluate(makeInput(glucose: nights(4, slopePerHour: 45))).first)
        #expect(block.windows.isEmpty)
    }

    // MARK: - Blocks

    @Test("Each basal time block is judged on its own") func testBlocks() throws {
        let input = makeInput(glucose: nights(4, slopePerHour: 10), basal: [(0, 1.0), (180, 0.8)])

        let results = evaluate(input)

        #expect(results.count == 2)
        #expect(results[0].blockStartMinute == 0)
        #expect(results[0].blockEndMinute == 180)
        #expect(results[1].blockStartMinute == 180)
        #expect(results[1].blockEndMinute == 1440)
        #expect(results[0].windows.count == 4)
        #expect(results[1].windows.count == 4)
        #expect(isClose(results[0].medianNeed, 1.2))
        #expect(isClose(results[1].medianNeed, 1.0))
        #expect(isClose(results[1].proposedRate, 0.9), "0.8 raised by at most 10 %, on a 0.05 step")
    }

    @Test("A suspended pump delivers nothing") func testSuspension() {
        let span = BasalTestSpan(start: time(day: 0, minutes: 0), end: time(day: 0, minutes: 120))
        let delivered = BasalTestEvaluator.deliveredBasal(
            in: span,
            tempBasals: [],
            suspensions: [BasalTestSpan(start: time(day: 0, minutes: 30), end: time(day: 0, minutes: 90))],
            schedule: [BasalTestScheduleEntry(startMinute: 0, value: 1.0)],
            calendar: calendar
        )
        #expect(isClose(delivered, 1.0))
    }

    @Test("A temp basal applies only for its duration and until the next one") func testTempBasalTimeline() {
        let span = BasalTestSpan(start: time(day: 0, minutes: 0), end: time(day: 0, minutes: 180))
        let delivered = BasalTestEvaluator.deliveredBasal(
            in: span,
            tempBasals: [
                // 30 min at 2.0, cut short after 15 min by the next one
                BasalTestTempBasal(start: time(day: 0, minutes: 0), durationMinutes: 30, rate: 2.0, isScheduledBasal: false),
                // 30 min at 0.0
                BasalTestTempBasal(start: time(day: 0, minutes: 15), durationMinutes: 30, rate: 0, isScheduledBasal: false),
                // back to schedule
                BasalTestTempBasal(start: time(day: 0, minutes: 120), durationMinutes: 1440, rate: 5, isScheduledBasal: true)
            ],
            suspensions: [],
            schedule: [BasalTestScheduleEntry(startMinute: 0, value: 1.0)],
            calendar: calendar
        )
        // 0.25 h * 2.0 + 0.5 h * 0 + 2.25 h * 1.0
        #expect(isClose(delivered, 2.75))
    }

    // MARK: - Suggested rate

    @Test("Suggestions land on pump rates and respect the step limit") func testProposedRate() {
        let propose = { (scheduled: Double, need: Double) in
            BasalTestEvaluator.proposedRate(
                scheduledRate: scheduled,
                need: need,
                maxStepFraction: 0.10,
                supportedBasalRates: nil
            )
        }

        #expect(isClose(propose(1.0, 1.5), 1.1), "Capped at 10 %")
        #expect(isClose(propose(1.0, 0.4), 0.9), "Capped at 10 %")
        #expect(isClose(propose(1.0, 1.06), 1.05), "Small needs give small steps")
        #expect(isClose(propose(0.2, 0.24), 0.25), "One pump increment when the estimate is more than half an increment away")
        #expect(propose(0.2, 0.21) == nil, "Too small for the pump to express")
        #expect(propose(0.05, 0.01) == nil, "Never below the lowest pump rate")
    }

    @Test("Suggestions use the rates the pump supports") func testProposedRateWithPumpRates() {
        let coarse = [0.5, 1.0, 1.5, 2.0]
        let proposed = BasalTestEvaluator.proposedRate(
            scheduledRate: 1.0,
            need: 1.3,
            maxStepFraction: 0.10,
            supportedBasalRates: coarse
        )
        #expect(isClose(proposed, 1.5), "The need is more than half an increment away, so one increment up")

        let unchanged = BasalTestEvaluator.proposedRate(
            scheduledRate: 1.0,
            need: 1.1,
            maxStepFraction: 0.10,
            supportedBasalRates: coarse
        )
        #expect(unchanged == nil)
    }

    @Test("No schedule or no data gives no results") func testEmptyInput() {
        #expect(evaluate(BasalTestInput()).isEmpty)
        let noGlucose = evaluate(makeInput(glucose: []))
        #expect(noGlucose.count == 1)
        #expect(noGlucose.first?.verdict == .notEnoughData)
    }
}
