import Foundation
import Swinject
import UserNotifications

extension Notification.Name {
    /// Posted by the Garmin manager whenever the data field asks for data.
    static let garminDatafieldDidRequestStatus = Notification.Name("garminDatafieldDidRequestStatus")
    /// Posted whenever the automation's settings or state change.
    static let sportAutomationDidChange = Notification.Name("sportAutomationDidChange")
}

// MARK: - Storage seam

protocol SportAutomationStore {
    func loadSettings() -> SportAutomationSettings
    func saveSettings(_ settings: SportAutomationSettings)
    func loadState() -> SportAutomationState
    func saveState(_ state: SportAutomationState)
}

final class FileSportAutomationStore: SportAutomationStore {
    private let storage: FileStorage

    init(storage: FileStorage) {
        self.storage = storage
    }

    func loadSettings() -> SportAutomationSettings {
        storage.retrieve(OpenAPS.Trio.sportAutomationSettings, as: SportAutomationSettings.self) ?? SportAutomationSettings()
    }

    func saveSettings(_ settings: SportAutomationSettings) {
        storage.save(settings, as: OpenAPS.Trio.sportAutomationSettings)
    }

    func loadState() -> SportAutomationState {
        storage.retrieve(OpenAPS.Trio.sportAutomationState, as: SportAutomationState.self) ?? SportAutomationState()
    }

    func saveState(_ state: SportAutomationState) {
        storage.save(state, as: OpenAPS.Trio.sportAutomationState)
    }
}

// MARK: - Manager

/// Starts and ends sport profiles from outside signals.
///
/// The only signal so far is the Garmin data field asking for data, which it does every five
/// minutes while an activity screen with the field is open. The decisions live in
/// `SportAutomationLogic`; this class feeds them and carries them out.
protocol SportAutomationManager {
    func settings() -> SportAutomationSettings
    func saveSettings(_ settings: SportAutomationSettings)
    func state() -> SportAutomationState
    func handleGarminSignal(now: Date) async
    func tick(now: Date) async
}

/// Tells the user what the automation did. Replaced in tests.
typealias SportAutomationNotifier = (_ title: String, _ body: String) -> Void

final class BaseSportAutomationManager: SportAutomationManager, Injectable, @unchecked Sendable {
    @Injected() private var storage: FileStorage!
    @Injected() private var sportProfileManager: SportProfileManager!
    @Injected() private var broadcaster: Broadcaster!

    private let customStore: SportAutomationStore?
    private let customProfileManager: SportProfileManager?
    private let customNotifier: SportAutomationNotifier?
    private let queue = SportAutomationQueue()
    private var signalObserver: NSObjectProtocol?

    init(
        resolver: Resolver,
        store: SportAutomationStore? = nil,
        profileManager: SportProfileManager? = nil,
        notifier: SportAutomationNotifier? = nil
    ) {
        customStore = store
        customProfileManager = profileManager
        customNotifier = notifier
        injectServices(resolver)

        broadcaster.register(DeterminationObserver.self, observer: self)
        signalObserver = Foundation.NotificationCenter.default.addObserver(
            forName: .garminDatafieldDidRequestStatus,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleGarminSignal(now: Date())
            }
        }
    }

    deinit {
        if let signalObserver {
            Foundation.NotificationCenter.default.removeObserver(signalObserver)
        }
    }

    private var store: SportAutomationStore {
        customStore ?? FileSportAutomationStore(storage: storage)
    }

    private var profiles: SportProfileManager {
        customProfileManager ?? sportProfileManager
    }

    // MARK: Settings

    func settings() -> SportAutomationSettings {
        store.loadSettings()
    }

    func saveSettings(_ settings: SportAutomationSettings) {
        var cleaned = settings
        cleaned.endTimeoutMinutes = min(
            max(settings.endTimeoutMinutes, SportAutomationLogic.timeoutRange.lowerBound),
            SportAutomationLogic.timeoutRange.upperBound
        )
        store.saveSettings(cleaned)
        announceChange()
    }

    func state() -> SportAutomationState {
        store.loadState()
    }

    // MARK: Signals

    func handleGarminSignal(now: Date) async {
        await run { [self] in
            let settings = store.loadSettings()
            let context = await currentContext()
            let result = SportAutomationLogic.onSignal(now: now, settings: settings, state: store.loadState(), context: context)
            store.saveState(result.state)
            await perform(result.action, settings: settings, reason: .activityStarted)
            announceChange()
        }
    }

    func tick(now: Date) async {
        await run { [self] in
            let settings = store.loadSettings()
            let state = store.loadState()
            // Nothing to watch unless the automation started something.
            guard state.startedProfileID != nil else { return }

            let context = await currentContext()
            let result = SportAutomationLogic.onTick(now: now, settings: settings, state: state, context: context)
            guard result.state != state || result.action != .none else { return }
            store.saveState(result.state)
            await perform(result.action, settings: settings, reason: .activityEnded)
            announceChange()
        }
    }

    private func currentContext() async -> SportAutomationContext {
        SportAutomationContext(
            run: profiles.currentRun(),
            profiles: profiles.profiles(),
            activeOverrideID: await profiles.activeOverrideID()
        )
    }

    // MARK: Actions

    private enum Reason {
        case activityStarted
        case activityEnded
    }

    private func perform(_ action: SportAutomationAction, settings: SportAutomationSettings, reason _: Reason) async {
        do {
            switch action {
            case .none:
                return

            case let .start(profileID, phaseIndex):
                try await profiles.start(profileID: profileID, phaseIndex: phaseIndex)
                // Remember which run is ours, so a run started by hand is never touched.
                var state = store.loadState()
                state.startedRunAt = profiles.currentRun()?.startedAt
                store.saveState(state)

                let name = profiles.currentRun()?.profileName ?? ""
                debug(.service, "Sport automation: started \"\(name)\" at phase \(phaseIndex + 1)")
                notify(
                    settings,
                    title: String(localized: "Sport profile started", comment: "Sport automation notification title"),
                    body: String(
                        localized: "\(name) was started because your Garmin activity began.",
                        comment: "Sport automation notification body"
                    )
                )

            case let .extend(minutes):
                try await profiles.extendCurrentPhase(byMinutes: minutes)
                debug(.service, "Sport automation: extended the running phase by \(minutes) min")

            case let .moveToPhase(index):
                let name = profiles.currentRun()?.profileName ?? ""
                try await profiles.jumpToPhase(index)
                debug(.service, "Sport automation: moved \"\(name)\" to phase \(index + 1)")
                notify(
                    settings,
                    title: String(localized: "Sport profile: recovery", comment: "Sport automation notification title"),
                    body: String(
                        localized: "\(name) moved to its recovery phase because your Garmin activity ended.",
                        comment: "Sport automation notification body"
                    )
                )

            case .stop:
                let name = profiles.currentRun()?.profileName ?? ""
                try await profiles.cancel()
                debug(.service, "Sport automation: stopped \"\(name)\"")
                notify(
                    settings,
                    title: String(localized: "Sport profile ended", comment: "Sport automation notification title"),
                    body: String(
                        localized: "\(name) was ended because your Garmin activity ended.",
                        comment: "Sport automation notification body"
                    )
                )
            }
        } catch {
            debug(.service, "Sport automation: \(action) failed: \(error)")
        }
    }

    private func notify(_ settings: SportAutomationSettings, title: String, body: String) {
        guard settings.notify else { return }
        if let customNotifier {
            customNotifier(title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "Trio.sportAutomation",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                debug(.service, "Sport automation: notification failed: \(error)")
            }
        }
    }

    private func announceChange() {
        Foundation.NotificationCenter.default.post(name: .sportAutomationDidChange, object: nil)
    }

    private func run(_ operation: @escaping @Sendable() async -> Void) async {
        await queue.run(operation)
    }
}

extension BaseSportAutomationManager: DeterminationObserver {
    func determinationDidUpdate(_: Determination) {
        Task { [weak self] in
            await self?.tick(now: Date())
        }
    }
}

// MARK: - Serialization

/// Signals and periodic checks arrive independently; each reads the state, decides and writes it
/// back, so they run one after another.
private actor SportAutomationQueue {
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
