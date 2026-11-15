import Foundation
import Swinject
import UserNotifications

extension Notification.Name {
    /// Posted by the notification delegate when a "Sport today?" notification was answered.
    /// `userInfo["action"]` holds the action identifier.
    static let sportReminderDidReceiveResponse = Notification.Name("sportReminderDidReceiveResponse")
    static let sportReminderDidChange = Notification.Name("sportReminderDidChange")
}

// MARK: - Seams

protocol SportReminderStore {
    func loadSettings() -> SportReminderSettings
    func saveSettings(_ settings: SportReminderSettings)
    func loadState() -> SportReminderState
    func saveState(_ state: SportReminderState)
}

final class FileSportReminderStore: SportReminderStore {
    private let storage: FileStorage

    init(storage: FileStorage) {
        self.storage = storage
    }

    func loadSettings() -> SportReminderSettings {
        storage.retrieve(OpenAPS.Trio.sportReminderSettings, as: SportReminderSettings.self) ?? SportReminderSettings()
    }

    func saveSettings(_ settings: SportReminderSettings) {
        storage.save(settings, as: OpenAPS.Trio.sportReminderSettings)
    }

    func loadState() -> SportReminderState {
        storage.retrieve(OpenAPS.Trio.sportReminderState, as: SportReminderState.self) ?? SportReminderState()
    }

    func saveState(_ state: SportReminderState) {
        storage.save(state, as: OpenAPS.Trio.sportReminderState)
    }
}

/// Puts the questions into the system's notification schedule. Replaced in tests.
protocol SportReminderScheduling {
    /// Replaces every pending question with one for each of the given dates.
    func replaceQuestions(with dates: [Date], profileName: String?) async
    /// Shows a plain message right away.
    func postMessage(title: String, body: String)
}

final class SystemSportReminderScheduler: SportReminderScheduling {
    private let center = UNUserNotificationCenter.current()

    func replaceQuestions(with dates: [Date], profileName: String?) async {
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(SportReminderLogic.requestIdentifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Sport today?", comment: "Sport reminder notification title")
        if let profileName {
            content.body = String(
                localized: "Are you planning to exercise today? The preparation phase of \(profileName) works best when it starts well before.",
                comment: "Sport reminder notification body"
            )
        } else {
            content.body = String(
                localized: "Are you planning to exercise today? Choose a sport profile in Trio to start it from here.",
                comment: "Sport reminder notification body"
            )
        }
        content.sound = .default
        content.categoryIdentifier = SportReminderLogic.categoryIdentifier

        for date in dates {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = SportReminderLogic.requestIdentifierPrefix + String(Int(date.timeIntervalSince1970))
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            } catch {
                debug(.service, "Sport reminder: could not schedule a question: \(error)")
            }
        }
    }

    func postMessage(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A different prefix, so rescheduling the questions does not remove it.
        let request = UNNotificationRequest(identifier: "Trio.sportReminderMessage", content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                debug(.service, "Sport reminder: notification failed: \(error)")
            }
        }
    }
}

extension SportReminderAnswer {
    var localizedTitle: String {
        switch self {
        case .startNow:
            return String(localized: "Start Preparation Now", comment: "Sport reminder notification action")
        case .startInOneHour:
            return String(localized: "Start in 1 Hour", comment: "Sport reminder notification action")
        case .notToday:
            return String(localized: "Not Today", comment: "Sport reminder notification action")
        }
    }
}

extension NotificationCategoryFactory {
    static func createSportReminderCategory() -> UNNotificationCategory {
        let actions = SportReminderAnswer.allCases.map { answer in
            UNNotificationAction(identifier: answer.rawValue, title: answer.localizedTitle, options: [])
        }
        return UNNotificationCategory(
            identifier: SportReminderLogic.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }
}

// MARK: - Manager

/// Asks "Sport today?" by notification and carries out the answer.
///
/// Questions are scheduled ahead for today and tomorrow, so they arrive without the app being
/// opened, and are renewed while the app runs. Nothing starts from an unanswered question.
protocol SportReminderManager {
    func settings() -> SportReminderSettings
    func saveSettings(_ settings: SportReminderSettings)
    func state() -> SportReminderState
    func reschedule(now: Date) async
    func handleAnswer(_ answer: SportReminderAnswer, now: Date) async
    func tick(now: Date) async
}

final class BaseSportReminderManager: SportReminderManager, Injectable, @unchecked Sendable {
    @Injected() private var storage: FileStorage!
    @Injected() private var sportProfileManager: SportProfileManager!
    @Injected() private var broadcaster: Broadcaster!

    private let customStore: SportReminderStore?
    private let customProfileManager: SportProfileManager?
    private let scheduler: SportReminderScheduling
    private let calendar: Calendar
    private let queue = SportReminderQueue()
    private var observers: [NSObjectProtocol] = []
    private var lastScheduledAt: Date?
    private let reactsToEvents: Bool

    /// How often the two-day window of questions is renewed while the app runs.
    private static let renewInterval: TimeInterval = 60 * 60

    init(
        resolver: Resolver,
        store: SportReminderStore? = nil,
        profileManager: SportProfileManager? = nil,
        scheduler: SportReminderScheduling? = nil,
        calendar: Calendar = .current,
        reactsToEvents: Bool = true
    ) {
        customStore = store
        customProfileManager = profileManager
        self.scheduler = scheduler ?? SystemSportReminderScheduler()
        self.calendar = calendar
        self.reactsToEvents = reactsToEvents
        injectServices(resolver)

        // Tests drive the manager by hand, with explicit times.
        guard reactsToEvents else { return }

        broadcaster.register(DeterminationObserver.self, observer: self)

        let center = Foundation.NotificationCenter.default
        observers.append(
            center.addObserver(forName: .sportReminderDidReceiveResponse, object: nil, queue: nil) { [weak self] notification in
                guard let identifier = notification.userInfo?["action"] as? String,
                      let answer = SportReminderAnswer(rawValue: identifier)
                else { return }
                Task { [weak self] in
                    await self?.handleAnswer(answer, now: Date())
                }
            }
        )
        // Questions stop while a profile runs and resume when it ends.
        observers.append(
            center.addObserver(forName: .sportProfileRunDidChange, object: nil, queue: nil) { [weak self] _ in
                Task { [weak self] in
                    await self?.reschedule(now: Date())
                }
            }
        )

        Task { [weak self] in
            await self?.reschedule(now: Date())
        }
    }

    deinit {
        observers.forEach { Foundation.NotificationCenter.default.removeObserver($0) }
    }

    private var store: SportReminderStore {
        customStore ?? FileSportReminderStore(storage: storage)
    }

    private var profiles: SportProfileManager {
        customProfileManager ?? sportProfileManager
    }

    // MARK: Settings

    func settings() -> SportReminderSettings {
        store.loadSettings()
    }

    func saveSettings(_ settings: SportReminderSettings) {
        store.saveSettings(SportReminderLogic.sanitized(settings))
        Foundation.NotificationCenter.default.post(name: .sportReminderDidChange, object: nil)
        guard reactsToEvents else { return }
        Task { [weak self] in
            await self?.reschedule(now: Date())
        }
    }

    func state() -> SportReminderState {
        store.loadState()
    }

    // MARK: Scheduling

    func reschedule(now: Date) async {
        await queue.run { [self] in
            await rescheduleUnqueued(now: now)
        }
    }

    private func rescheduleUnqueued(now: Date) async {
        let settings = store.loadSettings()
        let dates = SportReminderLogic.fireDates(
            now: now,
            settings: settings,
            state: store.loadState(),
            isProfileRunning: profiles.currentRun() != nil,
            calendar: calendar
        )
        let profileName = profiles.profiles().first(where: { $0.id == settings.profileID })?.name
        await scheduler.replaceQuestions(with: dates, profileName: profileName)
        lastScheduledAt = now
    }

    // MARK: Answers

    func handleAnswer(_ answer: SportReminderAnswer, now: Date) async {
        await queue.run { [self] in
            let settings = store.loadSettings()
            store.saveState(
                SportReminderLogic.state(after: answer, now: now, settings: settings, state: store.loadState(), calendar: calendar)
            )
            debug(.service, "Sport reminder: answered \(answer.rawValue)")

            if answer == .startNow {
                await start(profileID: settings.profileID)
            } else if answer == .startInOneHour, settings.profileID == nil {
                reportMissingProfile()
            }

            await rescheduleUnqueued(now: now)
            Foundation.NotificationCenter.default.post(name: .sportReminderDidChange, object: nil)
        }
    }

    /// Carries out a start planned with "in one hour" and keeps the questions scheduled ahead.
    func tick(now: Date) async {
        await queue.run { [self] in
            let state = store.loadState()
            if state.plannedStart != nil {
                let isRunning = profiles.currentRun() != nil
                let activeOverride = await profiles.activeOverrideID()
                let decision = SportReminderLogic.planDecision(
                    now: now,
                    state: state,
                    isProfileRunning: isRunning,
                    hasActiveOverride: activeOverride != nil
                )
                if decision != .wait {
                    var cleared = state
                    cleared.plannedStart = nil
                    cleared.plannedProfileID = nil
                    store.saveState(cleared)

                    switch decision {
                    case let .start(profileID):
                        await start(profileID: profileID)
                    case .skip:
                        scheduler.postMessage(
                            title: String(localized: "Sport profile not started", comment: "Sport reminder notification title"),
                            body: String(
                                localized: "The planned start was skipped because an override or a sport profile is already running.",
                                comment: "Sport reminder notification body"
                            )
                        )
                    case .expire,
                         .wait:
                        break
                    }
                    Foundation.NotificationCenter.default.post(name: .sportReminderDidChange, object: nil)
                }
            }

            if let last = lastScheduledAt, now.timeIntervalSince(last) < Self.renewInterval {
                return
            }
            await rescheduleUnqueued(now: now)
        }
    }

    private func start(profileID: String?) async {
        guard let profileID, profiles.profiles().contains(where: { $0.id == profileID }) else {
            reportMissingProfile()
            return
        }
        do {
            try await profiles.start(profileID: profileID, phaseIndex: 0)
            debug(.service, "Sport reminder: started sport profile")
        } catch {
            debug(.service, "Sport reminder: could not start sport profile: \(error)")
            scheduler.postMessage(
                title: String(localized: "Sport profile not started", comment: "Sport reminder notification title"),
                body: error.localizedDescription
            )
        }
    }

    private func reportMissingProfile() {
        scheduler.postMessage(
            title: String(localized: "Sport profile not started", comment: "Sport reminder notification title"),
            body: String(
                localized: "Choose a sport profile for the daily question in Trio first.",
                comment: "Sport reminder notification body"
            )
        )
    }
}

extension BaseSportReminderManager: DeterminationObserver {
    func determinationDidUpdate(_: Determination) {
        Task { [weak self] in
            await self?.tick(now: Date())
        }
    }
}

// MARK: - Serialization

private actor SportReminderQueue {
    private var tail: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable() async -> Void) async {
        let previous = tail
        let task = Task<Void, Never> {
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }
}
