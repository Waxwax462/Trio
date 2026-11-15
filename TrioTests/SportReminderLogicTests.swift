import Foundation
import Testing

@testable import Trio

@Suite("Sport Reminder Logic Tests") struct SportReminderLogicTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Midnight UTC.
    private let dayZero = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400))

    private func time(day: Int = 0, hour: Int, minute: Int = 0) -> Date {
        dayZero.addingTimeInterval(Double(day) * 86400 + Double(hour * 60 + minute) * 60)
    }

    private func enabledSettings() -> SportReminderSettings {
        var settings = SportReminderSettings()
        settings.enabled = true
        settings.profileID = "ride"
        return settings
    }

    private func dates(
        now: Date,
        settings: SportReminderSettings,
        state: SportReminderState = SportReminderState(),
        isProfileRunning: Bool = false
    ) -> [Date] {
        SportReminderLogic.fireDates(
            now: now,
            settings: settings,
            state: state,
            isProfileRunning: isProfileRunning,
            calendar: calendar
        )
    }

    // MARK: - Times of day

    @Test("Fixed times are used as they are, sorted and without duplicates") func testFixedTimes() {
        var settings = enabledSettings()
        settings.times = [18 * 60, 7 * 60, 7 * 60, 12 * 60 + 30]
        #expect(SportReminderLogic.minutesOfDay(settings) == [7 * 60, 12 * 60 + 30, 18 * 60])
    }

    @Test("Interval mode asks every N hours inside the window") func testInterval() {
        var settings = enabledSettings()
        settings.mode = .interval
        settings.intervalHours = 3
        settings.windowStart = 7 * 60
        settings.windowEnd = 20 * 60
        #expect(SportReminderLogic.minutesOfDay(settings) == [7 * 60, 10 * 60, 13 * 60, 16 * 60, 19 * 60])

        settings.intervalHours = 4
        settings.windowStart = 8 * 60
        settings.windowEnd = 20 * 60
        #expect(SportReminderLogic.minutesOfDay(settings) == [8 * 60, 12 * 60, 16 * 60, 20 * 60], "The end of the window is included")
    }

    @Test("Out-of-range values are pulled back") func testSanitize() {
        var settings = enabledSettings()
        settings.mode = .interval
        settings.intervalHours = 0
        settings.windowStart = 22 * 60
        settings.windowEnd = 6 * 60
        settings.times = [-5, 5000]

        let cleaned = SportReminderLogic.sanitized(settings)

        #expect(cleaned.intervalHours == 1)
        #expect(cleaned.windowEnd == cleaned.windowStart, "A window cannot end before it starts")
        #expect(cleaned.times == [0, 24 * 60 - 1])
        #expect(SportReminderLogic.minutesOfDay(settings) == [22 * 60])
    }

    @Test("There are never more than twelve questions a day") func testMaximumPerDay() {
        var settings = enabledSettings()
        settings.mode = .interval
        settings.intervalHours = 1
        settings.windowStart = 0
        settings.windowEnd = 24 * 60 - 1
        #expect(SportReminderLogic.minutesOfDay(settings).count == 12)

        settings.mode = .fixedTimes
        settings.times = Array(stride(from: 0, to: 20 * 60, by: 60))
        #expect(SportReminderLogic.minutesOfDay(settings).count == 12)
    }

    // MARK: - Due dates

    @Test("Questions are due at the remaining times today and all times tomorrow") func testFireDates() {
        let result = dates(now: time(hour: 9), settings: enabledSettings())
        #expect(result == [time(hour: 12), time(day: 1, hour: 7), time(day: 1, hour: 12)])
    }

    @Test("Nothing is due while the question is switched off") func testDisabled() {
        var settings = enabledSettings()
        settings.enabled = false
        #expect(dates(now: time(hour: 9), settings: settings).isEmpty)
    }

    @Test("An answered day gets no more questions, the next day does") func testAnsweredDay() {
        var state = SportReminderState()
        state.answeredDay = SportReminderLogic.dayKey(time(hour: 9), calendar: calendar)

        let result = dates(now: time(hour: 9), settings: enabledSettings(), state: state)

        #expect(result == [time(day: 1, hour: 7), time(day: 1, hour: 12)])
    }

    @Test("An answer from yesterday does not silence today") func testOldAnswer() {
        var state = SportReminderState()
        state.answeredDay = SportReminderLogic.dayKey(time(day: -1, hour: 9), calendar: calendar)

        let result = dates(now: time(hour: 6), settings: enabledSettings(), state: state)

        #expect(result.first == time(hour: 7))
        #expect(result.count == 4)
    }

    @Test("While a sport profile runs, the rest of today is skipped") func testRunningProfile() {
        let result = dates(now: time(hour: 9), settings: enabledSettings(), isProfileRunning: true)
        #expect(result == [time(day: 1, hour: 7), time(day: 1, hour: 12)])
    }

    // MARK: - Answers

    @Test("Every answer ends the questions for the day") func testAnswersMarkDay() {
        let now = time(hour: 9)
        let today = SportReminderLogic.dayKey(now, calendar: calendar)

        for answer in SportReminderAnswer.allCases {
            let state = SportReminderLogic.state(
                after: answer,
                now: now,
                settings: enabledSettings(),
                state: SportReminderState(),
                calendar: calendar
            )
            #expect(state.answeredDay == today)
        }
    }

    @Test("\"In one hour\" plans a start, the other answers clear any plan") func testPlannedStart() {
        let now = time(hour: 9)
        let planned = SportReminderLogic.state(
            after: .startInOneHour,
            now: now,
            settings: enabledSettings(),
            state: SportReminderState(),
            calendar: calendar
        )
        #expect(planned.plannedStart == time(hour: 10))
        #expect(planned.plannedProfileID == "ride")

        let cancelled = SportReminderLogic.state(
            after: .notToday,
            now: now,
            settings: enabledSettings(),
            state: planned,
            calendar: calendar
        )
        #expect(cancelled.plannedStart == nil)
        #expect(cancelled.plannedProfileID == nil)

        var noProfile = enabledSettings()
        noProfile.profileID = nil
        let nothing = SportReminderLogic.state(
            after: .startInOneHour,
            now: now,
            settings: noProfile,
            state: SportReminderState(),
            calendar: calendar
        )
        #expect(nothing.plannedStart == nil)
    }

    @Test("A planned start waits, starts, is skipped or expires") func testPlanDecision() {
        var state = SportReminderState()
        state.plannedStart = time(hour: 10)
        state.plannedProfileID = "ride"

        let decide = { (now: Date, running: Bool, override: Bool) in
            SportReminderLogic.planDecision(now: now, state: state, isProfileRunning: running, hasActiveOverride: override)
        }

        #expect(decide(time(hour: 9, minute: 55), false, false) == .wait)
        #expect(decide(time(hour: 10, minute: 2), false, false) == .start(profileID: "ride"))
        #expect(decide(time(hour: 10, minute: 2), true, false) == .skip)
        #expect(decide(time(hour: 10, minute: 2), false, true) == .skip, "A running override is never replaced by a planned start")
        #expect(decide(time(hour: 11), false, false) == .expire)

        #expect(
            SportReminderLogic.planDecision(
                now: time(hour: 10),
                state: SportReminderState(),
                isProfileRunning: false,
                hasActiveOverride: false
            ) == .wait
        )
    }
}
