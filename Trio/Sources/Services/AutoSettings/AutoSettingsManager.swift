import Foundation
import Swinject
import UserNotifications

extension Notification.Name {
    /// Posted when the learner's settings, proposals or log changed.
    static let autoSettingsDidChange = Notification.Name("autoSettingsDidChange")
}

// MARK: - Seams

protocol AutoSettingsStore {
    func loadSettings() -> AutoSettingsSettings
    func saveSettings(_ settings: AutoSettingsSettings)
    func loadState() -> AutoSettingsState
    func saveState(_ state: AutoSettingsState)
}

final class FileAutoSettingsStore: AutoSettingsStore {
    private let storage: FileStorage

    init(storage: FileStorage) {
        self.storage = storage
    }

    func loadSettings() -> AutoSettingsSettings {
        storage.retrieve(OpenAPS.Trio.autoSettings, as: AutoSettingsSettings.self) ?? AutoSettingsSettings()
    }

    func saveSettings(_ settings: AutoSettingsSettings) {
        storage.save(settings, as: OpenAPS.Trio.autoSettings)
    }

    func loadState() -> AutoSettingsState {
        storage.retrieve(OpenAPS.Trio.autoSettingsState, as: AutoSettingsState.self) ?? AutoSettingsState()
    }

    func saveState(_ state: AutoSettingsState) {
        storage.save(state, as: OpenAPS.Trio.autoSettingsState)
    }
}

/// What the learner needs to know about the rest of the app's configuration.
struct AutoSettingsEnvironment {
    var insulinModel = InsulinActionModel()
    var dynamicISFEnabled: Bool = false
    var maxBasal: Double?
}

enum AutoSettingsError: LocalizedError, Equatable {
    case nothingToUndo

    var errorDescription: String? {
        switch self {
        case .nothingToUndo:
            return String(
                localized: "This change can no longer be undone, because the value was changed again since.",
                comment: "Auto settings error"
            )
        }
    }
}

// MARK: - Texts

extension AutoSettingKind {
    var localizedName: String {
        switch self {
        case .basal: return String(localized: "Basal Rate", comment: "Auto settings value kind")
        case .sensitivity: return String(localized: "Insulin Sensitivity", comment: "Auto settings value kind")
        case .carbRatio: return String(localized: "Carb Ratio", comment: "Auto settings value kind")
        case .sportRecovery: return String(localized: "Sport Recovery", comment: "Auto settings value kind")
        }
    }

    /// A value of this kind as text, with its unit.
    func formatted(_ value: Double, units: GlucoseUnits) -> String {
        switch self {
        case .basal:
            return String(format: "%.2f", value) + " " + String(localized: "U/hr", comment: "Insulin unit per hour")
        case .sensitivity:
            return units == .mmolL
                ? String(format: "%.1f", value * 0.0555) + " mmol/L/U"
                : String(format: "%.0f", value) + " mg/dL/U"
        case .carbRatio:
            return String(format: "%.1f", value) + " g/U"
        case .sportRecovery:
            return String(format: "%.0f", value) + " %"
        }
    }
}

extension AutoSettingsChange {
    /// For example "Basal Rate 03:00: 0.80 → 0.85 U/hr".
    func localizedSummary(units: GlucoseUnits) -> String {
        let place = kind == .sportRecovery ? scopeName : TherapyProfileLogic.timeString(minutes: blockStartMinute)
        return "\(kind.localizedName) \(place): \(kind.formatted(oldValue, units: units)) → \(kind.formatted(newValue, units: units))"
    }
}

// MARK: - Manager

/// Runs the settings learner once a day and applies what it decides.
///
/// Therapy settings are written the way the editors write them, through the therapy profile
/// manager: the pump gets the basal schedule first, and if it refuses, nothing changes.
protocol AutoSettingsManager {
    func settings() -> AutoSettingsSettings
    func saveSettings(_ settings: AutoSettingsSettings)
    func state() -> AutoSettingsState
    /// Runs the learner now, whatever the time of day.
    @discardableResult func run(now: Date) async -> AutoSettingsState
    func tick(now: Date) async
    func undo(changeID: String, now: Date) async throws
    /// Makes the current values the baseline the learner stays close to.
    func confirmBaseline()
}

final class BaseAutoSettingsManager: AutoSettingsManager, Injectable, @unchecked Sendable {
    @Injected() private var storage: FileStorage!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var therapyProfileManager: TherapyProfileManager!
    @Injected() private var sportProfileManager: SportProfileManager!
    @Injected() private var settingsTestDataProvider: SettingsTestDataProvider!
    @Injected() private var broadcaster: Broadcaster!

    private let customStore: AutoSettingsStore?
    private let customDataProvider: SettingsTestDataProvider?
    private let customTherapyManager: TherapyProfileManager?
    private let customSportManager: SportProfileManager?
    private let customEnvironment: (() -> AutoSettingsEnvironment)?
    private let notifier: (String, String) -> Void
    private let calendar: Calendar
    private let reactsToEvents: Bool
    private let queue = AutoSettingsQueue()
    private var observers: [NSObjectProtocol] = []

    static let lookbackDays = 14
    /// The daily run waits for the first loop cycle after this hour, when the night's data is in.
    static let earliestHour = 3

    init(
        resolver: Resolver,
        store: AutoSettingsStore? = nil,
        dataProvider: SettingsTestDataProvider? = nil,
        therapyManager: TherapyProfileManager? = nil,
        sportManager: SportProfileManager? = nil,
        environment: (() -> AutoSettingsEnvironment)? = nil,
        notifier: ((String, String) -> Void)? = nil,
        calendar: Calendar = .current,
        reactsToEvents: Bool = true
    ) {
        customStore = store
        customDataProvider = dataProvider
        customTherapyManager = therapyManager
        customSportManager = sportManager
        customEnvironment = environment
        self.notifier = notifier ?? BaseAutoSettingsManager.postNotification
        self.calendar = calendar
        self.reactsToEvents = reactsToEvents
        injectServices(resolver)

        // Tests drive the manager by hand, with explicit times.
        guard reactsToEvents else { return }

        broadcaster.register(DeterminationObserver.self, observer: self)
        observers.append(
            Foundation.NotificationCenter.default
                .addObserver(forName: .sportProfileRunDidChange, object: nil, queue: nil) { [weak self] _ in
                    Task { [weak self] in
                        await self?.syncSpans(now: Date())
                    }
                }
        )
    }

    deinit {
        observers.forEach { Foundation.NotificationCenter.default.removeObserver($0) }
    }

    private var store: AutoSettingsStore { customStore ?? FileAutoSettingsStore(storage: storage) }
    private var dataProvider: SettingsTestDataProvider { customDataProvider ?? settingsTestDataProvider }
    private var therapy: TherapyProfileManager { customTherapyManager ?? therapyProfileManager }
    private var sport: SportProfileManager { customSportManager ?? sportProfileManager }

    private var environment: AutoSettingsEnvironment {
        if let customEnvironment { return customEnvironment() }
        let preferences = settingsManager.preferences
        let pumpSettings = settingsManager.pumpSettings
        let peak = preferences.useCustomPeakTime
            ? Double(preferences.insulinPeakTime)
            : (preferences.curve == .ultraRapid ? 55 : 75)
        return AutoSettingsEnvironment(
            insulinModel: InsulinActionModel(peakMinutes: peak, durationMinutes: Double(pumpSettings.insulinActionCurve) * 60),
            dynamicISFEnabled: preferences.useNewFormula,
            maxBasal: Double(pumpSettings.maxBasal)
        )
    }

    private var units: GlucoseUnits {
        customEnvironment == nil ? settingsManager.settings.units : .mgdL
    }

    // MARK: Settings

    func settings() -> AutoSettingsSettings {
        store.loadSettings()
    }

    func saveSettings(_ settings: AutoSettingsSettings) {
        var cleaned = settings
        cleaned.sportAfterEffectHours = min(max(settings.sportAfterEffectHours, 0), 24)
        store.saveSettings(cleaned)
        announce()
    }

    func state() -> AutoSettingsState {
        store.loadState()
    }

    func confirmBaseline() {
        var state = store.loadState()
        AutoSettingsEngine.confirmBaseline(&state, values: currentValues().all)
        store.saveState(state)
        announce()
    }

    // MARK: Running

    func tick(now: Date) async {
        guard store.loadSettings().mode != .off else { return }
        await syncSpans(now: now)

        let state = store.loadState()
        if let lastRun = state.lastRun, calendar.isDate(lastRun, inSameDayAs: now) { return }
        guard calendar.component(.hour, from: now) >= Self.earliestHour else { return }
        // Settings are not changed underneath a running sport profile.
        guard sport.currentRun() == nil else { return }

        await run(now: now)
    }

    @discardableResult func run(now: Date) async -> AutoSettingsState {
        await queue.run { [self] in
            await runUnqueued(now: now)
        }
        return store.loadState()
    }

    private func runUnqueued(now: Date) async {
        let settings = store.loadSettings()
        guard settings.mode != .off else { return }

        let input: BasalTestInput
        do {
            input = try await dataProvider.loadBasalTestInput(days: Self.lookbackDays, now: now)
        } catch {
            debug(.service, "Auto settings: could not load history: \(error)")
            return
        }

        var state = store.loadState()
        let active = activeProfile()
        let sportProfiles = sport.profiles()
        AutoSettingsEngine.syncProfileSpans(&state, activeProfileID: active.id, now: now)
        AutoSettingsEngine.syncSportSpans(&state, run: sport.currentRun(), profiles: sportProfiles, now: now)

        let environment = self.environment
        var context = AutoSettingsContext(
            now: now,
            calendar: calendar,
            settings: settings,
            state: state,
            input: input,
            therapy: therapy.currentSettings(),
            activeProfileID: active.id,
            activeProfileName: active.name
        )
        context.sportProfiles = sportProfiles
        context.supportedBasalRates = therapy.supportedBasalRates?.map { Double($0) }
        context.maxBasal = environment.maxBasal
        context.insulinModel = environment.insulinModel
        context.dynamicISFEnabled = environment.dynamicISFEnabled

        let outcome = AutoSettingsEngine.run(context)
        state = outcome.state
        // Saved before anything is applied, so a crash in between cannot repeat the run.
        store.saveState(state)

        let applied = await apply(outcome.changes, state: &state)
        store.saveState(state)
        debug(.service, "Auto settings: ran in \(settings.mode.rawValue) mode, \(applied.count) change(s) applied")

        if !applied.isEmpty, settings.notify {
            let units = self.units
            notifier(
                String(localized: "Trio adjusted your settings", comment: "Auto settings notification title"),
                applied.map { $0.localizedSummary(units: units) }.joined(separator: "\n")
            )
        }
        announce()
    }

    /// Writes the changes and records the ones that really went through.
    private func apply(_ changes: [AutoSettingsChange], state: inout AutoSettingsState) async -> [AutoSettingsChange] {
        var applied: [AutoSettingsChange] = []
        let active = activeProfile()

        var snapshot = therapy.currentSettings()
        var written: [AutoSettingsChange] = []
        for change in changes where change.kind != .sportRecovery {
            if let next = AutoSettingsEngine.applying(change, to: snapshot, profileID: active.id) {
                snapshot = next
                written.append(change)
            }
        }
        if !written.isEmpty {
            do {
                try await therapy.applySettings(snapshot)
                for change in written {
                    AutoSettingsEngine.record(change, in: &state)
                    applied.append(change)
                }
            } catch {
                debug(.service, "Auto settings: therapy settings not changed: \(error.localizedDescription)")
            }
        }

        for change in changes where change.kind == .sportRecovery {
            guard let profile = AutoSettingsEngine.applying(change, to: sport.profiles()) else { continue }
            do {
                try sport.saveProfile(profile)
                AutoSettingsEngine.record(change, in: &state)
                applied.append(change)
            } catch {
                debug(.service, "Auto settings: sport profile not changed: \(error.localizedDescription)")
            }
        }
        return applied
    }

    // MARK: Undo

    func undo(changeID: String, now: Date) async throws {
        let done: Bool = await queue.run { [self] in
            var state = store.loadState()
            guard let original = state.history.first(where: { $0.id == changeID }),
                  let undo = AutoSettingsEngine.undoChange(
                      for: changeID,
                      state: state,
                      currentValue: currentValues().byKey[original.key],
                      now: now
                  )
            else { return false }

            let applied = await apply([undo], state: &state)
            store.saveState(state)
            announce()
            return !applied.isEmpty
        }
        if !done { throw AutoSettingsError.nothingToUndo }
    }

    // MARK: Helpers

    private func activeProfile() -> (id: String, name: String) {
        let profile = therapy.activeProfile()
        return (profile?.id ?? "default", profile?.name ?? "")
    }

    private func currentValues() -> (all: [AutoSettingValue], byKey: [String: Double]) {
        let active = activeProfile()
        let all = AutoSettingsEngine.therapyValues(therapy.currentSettings(), profileID: active.id, profileName: active.name)
            + AutoSettingsEngine.sportValues(sport.profiles())
        return (all, Dictionary(all.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Keeps the logs of sport phases and active therapy profiles current between runs.
    private func syncSpans(now: Date) async {
        await queue.run { [self] in
            guard store.loadSettings().mode != .off else { return }
            var state = store.loadState()
            let profileChanged = AutoSettingsEngine.syncProfileSpans(&state, activeProfileID: activeProfile().id, now: now)
            let sportChanged = AutoSettingsEngine.syncSportSpans(
                &state,
                run: sport.currentRun(),
                profiles: sport.profiles(),
                now: now
            )
            if profileChanged || sportChanged {
                store.saveState(state)
            }
        }
    }

    private func announce() {
        Foundation.NotificationCenter.default.post(name: .autoSettingsDidChange, object: nil)
    }

    private static func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "Trio.autoSettings." + String(Int(Date().timeIntervalSince1970)),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                debug(.service, "Auto settings: notification failed: \(error)")
            }
        }
    }
}

extension BaseAutoSettingsManager: DeterminationObserver {
    func determinationDidUpdate(_: Determination) {
        Task { [weak self] in
            await self?.tick(now: Date())
        }
    }
}

// MARK: - Serialization

private actor AutoSettingsQueue {
    private var tail: Task<Void, Never>?

    @discardableResult func run<T: Sendable>(_ operation: @escaping @Sendable() async -> T) async -> T {
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}
