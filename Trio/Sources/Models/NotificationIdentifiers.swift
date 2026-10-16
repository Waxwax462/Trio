import Foundation
import UserNotifications

enum NotificationCategoryIdentifier: String {
    case trioAlert = "Trio.alert"
}

enum NotificationResponseAction: String, CaseIterable {
    case stop = "Trio.stop"
    case snooze15 = "Trio.snooze15"
    case snooze1hr = "Trio.snooze1hr"
    case snooze3hr = "Trio.snooze3hr"
    case snooze6hr = "Trio.snooze6hr"

    /// Snooze choices only; `.stop` is offered separately on notifications.
    static var allCases: [NotificationResponseAction] { [.snooze15, .snooze1hr, .snooze3hr, .snooze6hr] }

    var duration: TimeInterval {
        TimeInterval(minutes) * 60
    }

    /// 0 means "stop the alarm without snoozing".
    var minutes: Int {
        switch self {
        case .stop:
            return 0
        case .snooze15:
            return 15
        case .snooze1hr:
            return 60
        case .snooze3hr:
            return 180
        case .snooze6hr:
            return 360
        }
    }

    var localizedTitle: String {
        switch self {
        case .stop:
            return String(localized: "Stop Alarm", comment: "Acknowledge the alarm without snoozing")
        case .snooze15:
            return String(localized: "Snooze 15 min", comment: "Snooze glucose alerts for 15 minutes")
        case .snooze1hr:
            return String(localized: "Snooze 1 hr", comment: "Snooze glucose alerts for 1 hour")
        case .snooze3hr:
            return String(localized: "Snooze 3 hrs", comment: "Snooze glucose alerts for 3 hours")
        case .snooze6hr:
            return String(localized: "Snooze 6 hrs", comment: "Snooze glucose alerts for 6 hours")
        }
    }
}

// MARK: - NotificationCategoryFactory

enum NotificationCategoryFactory {
    static func createGlucoseCategory() -> UNNotificationCategory {
        let snoozeActions = ([NotificationResponseAction.stop] + NotificationResponseAction.allCases).map { action in
            UNNotificationAction(
                identifier: action.rawValue,
                title: action.localizedTitle,
                options: []
            )
        }

        // `.customDismissAction` — otherwise iOS swallows swipes silently and
        // the in-app banner outlives the notification.
        return UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.trioAlert.rawValue,
            actions: snoozeActions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }
}
