import Foundation

struct GlucoseAlertConfiguration: Codable, Equatable {
    var dayStart: TimeOfDay
    var nightStart: TimeOfDay
    /// Force Trio alarms on even when the CGM advertises its own.
    var forceTrioAlertsWhenCGMProvidesOwn: Bool
    /// During the day window alarms only vibrate (repeating) instead of
    /// playing their sound; at night the configured sound plays.
    var vibrateOnlyDuringDay: Bool

    init(
        dayStart: TimeOfDay = TimeOfDay(hour: 6, minute: 0),
        nightStart: TimeOfDay = TimeOfDay(hour: 22, minute: 0),
        forceTrioAlertsWhenCGMProvidesOwn: Bool = false,
        vibrateOnlyDuringDay: Bool = false
    ) {
        self.dayStart = dayStart
        self.nightStart = nightStart
        self.forceTrioAlertsWhenCGMProvidesOwn = forceTrioAlertsWhenCGMProvidesOwn
        self.vibrateOnlyDuringDay = vibrateOnlyDuringDay
    }

    private enum CodingKeys: String, CodingKey {
        case dayStart
        case nightStart
        case forceTrioAlertsWhenCGMProvidesOwn
        case vibrateOnlyDuringDay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayStart = try container.decode(TimeOfDay.self, forKey: .dayStart)
        nightStart = try container.decode(TimeOfDay.self, forKey: .nightStart)
        forceTrioAlertsWhenCGMProvidesOwn = try container.decodeIfPresent(
            Bool.self,
            forKey: .forceTrioAlertsWhenCGMProvidesOwn
        ) ?? false
        vibrateOnlyDuringDay = try container.decodeIfPresent(Bool.self, forKey: .vibrateOnlyDuringDay) ?? false
    }

    /// Resolve whether `date` falls into the user's "night" window. Mirrors
    /// LoopFollow's logic: handles both same-day (06→22) and wrap-around
    /// (22→06) ranges. When `nightStart >= dayStart`, night is "later than
    /// nightStart OR earlier than dayStart"; otherwise night is the slice
    /// between nightStart and dayStart.
    func isNight(at date: Date, calendar: Calendar = .current) -> Bool {
        let startOfDay = calendar.startOfDay(for: date)
        guard
            let dayStartDate = calendar.date(
                bySettingHour: dayStart.hour,
                minute: dayStart.minute,
                second: 0,
                of: startOfDay
            ),
            let nightStartDate = calendar.date(
                bySettingHour: nightStart.hour,
                minute: nightStart.minute,
                second: 0,
                of: startOfDay
            )
        else { return false }

        if nightStartDate >= dayStartDate {
            return date >= nightStartDate || date < dayStartDate
        } else {
            return date >= nightStartDate && date < dayStartDate
        }
    }
}
