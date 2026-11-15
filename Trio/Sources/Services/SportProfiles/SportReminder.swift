import Foundation

// MARK: - Models

enum SportReminderMode: String, JSON, CaseIterable {
    /// Ask at chosen times of day.
    case fixedTimes
    /// Ask every few hours within a daily window.
    case interval
}

/// When and about which profile the "Sport today?" question is asked.
struct SportReminderSettings: JSON, Equatable {
    var enabled: Bool = false
    var mode: SportReminderMode = .fixedTimes
    /// Minutes after midnight, used in `fixedTimes` mode.
    var times: [Int] = [7 * 60, 12 * 60]
    /// Used in `interval` mode.
    var intervalHours: Int = 3
    /// Minutes after midnight; the first question of the day in `interval` mode.
    var windowStart: Int = 7 * 60
    /// Minutes after midnight; no question after this in `interval` mode.
    var windowEnd: Int = 20 * 60
    /// The sport profile the answers start.
    var profileID: String?
}

struct SportReminderState: JSON, Equatable {
    /// The day (`yyyy-MM-dd`) on which the question was answered. No more questions that day.
    var answeredDay: String?
    /// A start the user asked for with "in one hour".
    var plannedStart: Date?
    var plannedProfileID: String?
}

/// The answers a notification offers.
enum SportReminderAnswer: String, CaseIterable {
    case startNow = "Trio.sportReminder.startNow"
    case startInOneHour = "Trio.sportReminder.startInOneHour"
    case notToday = "Trio.sportReminder.notToday"
}

/// What to do about a planned start at a given moment.
enum SportReminderPlanDecision: Equatable {
    case wait
    case start(profileID: String)
    /// Something else is running; the planned start is dropped.
    case skip
    /// The planned time is long past, for example after the phone was off.
    case expire
}

// MARK: - Logic

/// Pure rules for the "Sport today?" question.
enum SportReminderLogic {
    static let categoryIdentifier = "Trio.sportReminder"
    static let requestIdentifierPrefix = "Trio.sportReminder."
    static let maxTimesPerDay = 12
    static let intervalRange: ClosedRange<Int> = 1 ... 12
    static let delayedStart: TimeInterval = 60 * 60
    /// A planned start older than this is not carried out any more.
    static let planExpiry: TimeInterval = 30 * 60

    /// Brings every value into its allowed range.
    static func sanitized(_ settings: SportReminderSettings) -> SportReminderSettings {
        var cleaned = settings
        let day = 24 * 60
        cleaned.times = Array(Set(settings.times.map { min(max($0, 0), day - 1) })).sorted().prefix(maxTimesPerDay).map { $0 }
        cleaned.intervalHours = min(max(settings.intervalHours, intervalRange.lowerBound), intervalRange.upperBound)
        cleaned.windowStart = min(max(settings.windowStart, 0), day - 1)
        cleaned.windowEnd = min(max(settings.windowEnd, cleaned.windowStart), day - 1)
        return cleaned
    }

    /// The times of day, in minutes after midnight, at which the question is asked.
    static func minutesOfDay(_ settings: SportReminderSettings) -> [Int] {
        let cleaned = sanitized(settings)
        switch cleaned.mode {
        case .fixedTimes:
            return cleaned.times
        case .interval:
            var result: [Int] = []
            var minute = cleaned.windowStart
            while minute <= cleaned.windowEnd, result.count < maxTimesPerDay {
                result.append(minute)
                minute += cleaned.intervalHours * 60
            }
            return result
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// The moments at which a question is due, from `now` to the end of the last of `days` days.
    /// Leaves out a day that was already answered and, while a sport profile runs, the rest of today.
    static func fireDates(
        now: Date,
        settings: SportReminderSettings,
        state: SportReminderState,
        isProfileRunning: Bool,
        calendar: Calendar,
        days: Int = 2
    ) -> [Date] {
        guard settings.enabled else { return [] }
        let minutes = minutesOfDay(settings)
        let today = calendar.startOfDay(for: now)
        var result: [Date] = []

        for offset in 0 ..< max(days, 1) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if dayKey(day, calendar: calendar) == state.answeredDay { continue }
            if offset == 0, isProfileRunning { continue }

            for minute in minutes {
                guard let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day),
                      date > now
                else { continue }
                result.append(date)
            }
        }
        return result.sorted()
    }

    /// The state after an answer. `startNow` itself is carried out by the caller.
    static func state(
        after answer: SportReminderAnswer,
        now: Date,
        settings: SportReminderSettings,
        state: SportReminderState,
        calendar: Calendar
    ) -> SportReminderState {
        var next = state
        next.answeredDay = dayKey(now, calendar: calendar)
        switch answer {
        case .startNow,
             .notToday:
            next.plannedStart = nil
            next.plannedProfileID = nil
        case .startInOneHour:
            if let profileID = settings.profileID {
                next.plannedStart = now.addingTimeInterval(delayedStart)
                next.plannedProfileID = profileID
            }
        }
        return next
    }

    static func planDecision(
        now: Date,
        state: SportReminderState,
        isProfileRunning: Bool,
        hasActiveOverride: Bool
    ) -> SportReminderPlanDecision {
        guard let plannedStart = state.plannedStart, let profileID = state.plannedProfileID else { return .wait }
        guard now >= plannedStart else { return .wait }
        if now.timeIntervalSince(plannedStart) > planExpiry { return .expire }
        if isProfileRunning || hasActiveOverride { return .skip }
        return .start(profileID: profileID)
    }
}
