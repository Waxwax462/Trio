import Foundation
import LoopKit
import Swinject

// MARK: - Storage seam

/// Where therapy settings and the profile library live. The app reads and writes the same files
/// the editors and the algorithm use; tests substitute an in-memory store.
protocol TherapySettingsStore {
    func loadCurrentSettings() -> TherapySettingsSnapshot
    func saveCurrentSettings(_ settings: TherapySettingsSnapshot)
    func saveCurrentBasal(_ basal: [BasalProfileEntry])
    func loadLibrary() -> TherapyProfileLibrary?
    func saveLibrary(_ library: TherapyProfileLibrary)
}

final class FileTherapySettingsStore: TherapySettingsStore {
    private let storage: FileStorage

    init(storage: FileStorage) {
        self.storage = storage
    }

    func loadCurrentSettings() -> TherapySettingsSnapshot {
        let basal = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
            ?? [BasalProfileEntry](from: OpenAPS.defaults(for: OpenAPS.Settings.basalProfile))
            ?? []
        let sensitivities = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
            ?? InsulinSensitivities(from: OpenAPS.defaults(for: OpenAPS.Settings.insulinSensitivities))
            ?? InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: [])
        let carbRatios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
            ?? CarbRatios(from: OpenAPS.defaults(for: OpenAPS.Settings.carbRatios))
            ?? CarbRatios(units: .grams, schedule: [])
        let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)
            ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
            ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        return TherapySettingsSnapshot(basal: basal, sensitivities: sensitivities, carbRatios: carbRatios, targets: targets)
    }

    func saveCurrentSettings(_ settings: TherapySettingsSnapshot) {
        storage.save(settings.basal, as: OpenAPS.Settings.basalProfile)
        storage.save(settings.sensitivities, as: OpenAPS.Settings.insulinSensitivities)
        storage.save(settings.carbRatios, as: OpenAPS.Settings.carbRatios)
        storage.save(settings.targets, as: OpenAPS.Settings.bgTargets)
    }

    func saveCurrentBasal(_ basal: [BasalProfileEntry]) {
        storage.save(basal, as: OpenAPS.Settings.basalProfile)
    }

    func loadLibrary() -> TherapyProfileLibrary? {
        storage.retrieve(OpenAPS.Trio.therapyProfiles, as: TherapyProfileLibrary.self)
    }

    func saveLibrary(_ library: TherapyProfileLibrary) {
        storage.save(library, as: OpenAPS.Trio.therapyProfiles)
    }
}

// MARK: - Errors

enum TherapyProfileError: LocalizedError, Equatable {
    case profileNotFound
    case nameMissing
    case nameAlreadyUsed
    case activeProfileCannotBeDeleted
    case invalidSettings([TherapyProfileProblem])
    case noPump
    case pumpSyncFailed(String)

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return String(localized: "The therapy profile no longer exists.", comment: "Therapy profile error")
        case .nameMissing:
            return String(localized: "Enter a name for the therapy profile.", comment: "Therapy profile error")
        case .nameAlreadyUsed:
            return String(localized: "A therapy profile with this name already exists.", comment: "Therapy profile error")
        case .activeProfileCannotBeDeleted:
            return String(localized: "The active therapy profile cannot be deleted.", comment: "Therapy profile error")
        case let .invalidSettings(problems):
            let details = problems.prefix(3).map(\.localizedText).joined(separator: "\n")
            return String(
                localized: "The settings contain values that are not allowed:\n\(details)",
                comment: "Therapy profile error, followed by a list of problems"
            )
        case .noPump:
            return String(
                localized: "No pump is connected. Basal rates can only be changed with a pump.",
                comment: "Therapy profile error"
            )
        case let .pumpSyncFailed(reason):
            return String(
                localized: "The pump did not accept the basal rates. Nothing was changed.\n\(reason)",
                comment: "Therapy profile error, followed by the pump's error message"
            )
        }
    }
}

extension TherapySettingCategory {
    var localizedName: String {
        switch self {
        case .basal: return String(localized: "Basal Rates")
        case .sensitivity: return String(localized: "Insulin Sensitivities")
        case .carbRatio: return String(localized: "Carb Ratios")
        case .target: return String(localized: "Glucose Targets")
        }
    }
}

extension TherapyProfileProblem {
    var localizedText: String {
        switch self {
        case let .emptySchedule(category):
            return String(localized: "\(category.localizedName): no entries", comment: "Therapy profile problem")
        case let .scheduleDoesNotStartAtMidnight(category):
            return String(localized: "\(category.localizedName): first entry must start at 00:00", comment: "Therapy profile problem")
        case let .scheduleNotAscending(category):
            return String(localized: "\(category.localizedName): entries are not in order", comment: "Therapy profile problem")
        case let .valueOutOfRange(category, minutes, value):
            let time = TherapyProfileLogic.timeString(minutes: minutes)
            return String(
                localized: "\(category.localizedName) at \(time): \(value.description) is out of range",
                comment: "Therapy profile problem"
            )
        case let .basalRateNotSupportedByPump(minutes, value):
            let time = TherapyProfileLogic.timeString(minutes: minutes)
            return String(
                localized: "Basal rate at \(time): \(value.description) U/hr is not supported by the pump",
                comment: "Therapy profile problem"
            )
        case let .basalRateAboveMaxBasal(minutes, value):
            let time = TherapyProfileLogic.timeString(minutes: minutes)
            return String(
                localized: "Basal rate at \(time): \(value.description) U/hr is above the maximum basal rate",
                comment: "Therapy profile problem"
            )
        }
    }
}

// MARK: - Manager

/// Sends a basal schedule to the pump. Throws when the pump refuses or cannot be reached.
typealias BasalScheduleSync = ([BasalProfileEntry]) async throws -> Void

/// Keeps named sets of therapy settings and switches between them.
///
/// The four settings files remain the only input of the algorithm and of the existing editors.
/// Switching copies the current files back into the profile that was active, then writes the
/// chosen profile into the files. Basal rates go to the pump first; if the pump refuses, nothing
/// is written.
protocol TherapyProfileManager {
    var supportedBasalRates: [Decimal]? { get }
    func library() -> TherapyProfileLibrary
    func activeProfile() -> TherapyProfile?
    func currentSettings() -> TherapySettingsSnapshot
    @discardableResult func createProfile(name: String, basedOn sourceID: String?, percentage: Decimal) throws -> TherapyProfile
    func renameProfile(id: String, to name: String) throws
    func deleteProfile(id: String) throws
    func differences(toProfile id: String) -> [TherapyProfileDifference]
    func activateProfile(id: String) async throws
    func applyBasalProfile(_ basal: [BasalProfileEntry]) async throws
}

final class BaseTherapyProfileManager: TherapyProfileManager, Injectable, @unchecked Sendable {
    @Injected() private var storage: FileStorage!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var nightscoutManager: NightscoutManager!
    @Injected() private var tidepoolManager: TidepoolManager!
    @Injected() private var apsManager: APSManager!

    private let customStore: TherapySettingsStore?
    private let customBasalSync: BasalScheduleSync?
    private let customSupportedBasalRates: [Decimal]?
    private let performsSideEffects: Bool
    private let lock = NSRecursiveLock()

    /// The extra parameters replace storage, pump and uploads, so the switching rules can be
    /// exercised without devices.
    init(
        resolver: Resolver,
        store: TherapySettingsStore? = nil,
        basalSync: BasalScheduleSync? = nil,
        supportedBasalRates: [Decimal]? = nil,
        performsSideEffects: Bool = true
    ) {
        customStore = store
        customBasalSync = basalSync
        customSupportedBasalRates = supportedBasalRates
        self.performsSideEffects = performsSideEffects
        injectServices(resolver)
    }

    private var store: TherapySettingsStore {
        customStore ?? FileTherapySettingsStore(storage: storage)
    }

    var supportedBasalRates: [Decimal]? {
        if let customSupportedBasalRates { return customSupportedBasalRates }
        return deviceDataManager.pumpManager?.supportedBasalRates
            .filter { $0 > 0 }
            .map { rounded(Decimal($0), scale: 3, roundingMode: .plain) }
    }

    private var maxBasal: Decimal? {
        guard performsSideEffects else { return nil }
        return settingsManager.pumpSettings.maxBasal
    }

    // MARK: Reading

    func currentSettings() -> TherapySettingsSnapshot {
        store.loadCurrentSettings()
    }

    /// Returns the library, creating it from the current settings the first time it is asked for.
    func library() -> TherapyProfileLibrary {
        lock.lock()
        defer { lock.unlock() }

        if let stored = store.loadLibrary(),
           let activeID = stored.activeProfileID,
           stored.profiles.contains(where: { $0.id == activeID })
        {
            return stored
        }

        let initial = TherapyProfile(
            id: UUID().uuidString,
            name: String(localized: "Standard", comment: "Name of the first therapy profile"),
            settings: store.loadCurrentSettings(),
            updatedAt: Date()
        )
        var profiles = store.loadLibrary()?.profiles ?? []
        profiles.insert(initial, at: 0)
        let created = TherapyProfileLibrary(activeProfileID: initial.id, profiles: profiles)
        store.saveLibrary(created)
        return created
    }

    func activeProfile() -> TherapyProfile? {
        let current = library()
        return current.profiles.first { $0.id == current.activeProfileID }
    }

    /// The settings a profile stands for right now. For the active profile these are the files,
    /// because the editors write there.
    private func effectiveSettings(of profile: TherapyProfile, in library: TherapyProfileLibrary) -> TherapySettingsSnapshot {
        profile.id == library.activeProfileID ? store.loadCurrentSettings() : profile.settings
    }

    func differences(toProfile id: String) -> [TherapyProfileDifference] {
        let current = library()
        guard let target = current.profiles.first(where: { $0.id == id }) else { return [] }
        return TherapyProfileLogic.differences(
            from: store.loadCurrentSettings(),
            to: effectiveSettings(of: target, in: current)
        )
    }

    // MARK: Editing the library

    @discardableResult func createProfile(
        name: String,
        basedOn sourceID: String?,
        percentage: Decimal
    ) throws -> TherapyProfile {
        lock.lock()
        defer { lock.unlock() }

        var current = library()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TherapyProfileError.nameMissing }
        guard !current.profiles.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw TherapyProfileError.nameAlreadyUsed
        }

        let source: TherapySettingsSnapshot
        if let sourceID {
            guard let profile = current.profiles.first(where: { $0.id == sourceID }) else {
                throw TherapyProfileError.profileNotFound
            }
            source = effectiveSettings(of: profile, in: current)
        } else {
            source = store.loadCurrentSettings()
        }

        let settings = TherapyProfileLogic.scaled(source, percentage: percentage, supportedBasalRates: supportedBasalRates)
        let problems = TherapyProfileLogic.validate(settings, supportedBasalRates: supportedBasalRates, maxBasal: maxBasal)
        guard problems.isEmpty else { throw TherapyProfileError.invalidSettings(problems) }

        let profile = TherapyProfile(id: UUID().uuidString, name: trimmed, settings: settings, updatedAt: Date())
        current.profiles.append(profile)
        store.saveLibrary(current)
        return profile
    }

    func renameProfile(id: String, to name: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var current = library()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TherapyProfileError.nameMissing }
        guard let index = current.profiles.firstIndex(where: { $0.id == id }) else {
            throw TherapyProfileError.profileNotFound
        }
        let isTaken = current.profiles.contains { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        guard !isTaken else { throw TherapyProfileError.nameAlreadyUsed }

        current.profiles[index].name = trimmed
        store.saveLibrary(current)
    }

    func deleteProfile(id: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var current = library()
        guard current.activeProfileID != id else { throw TherapyProfileError.activeProfileCannotBeDeleted }
        guard current.profiles.contains(where: { $0.id == id }) else { throw TherapyProfileError.profileNotFound }
        current.profiles.removeAll { $0.id == id }
        store.saveLibrary(current)
    }

    // MARK: Switching

    func activateProfile(id: String) async throws {
        var current = library()
        guard let target = current.profiles.first(where: { $0.id == id }) else {
            throw TherapyProfileError.profileNotFound
        }
        guard current.activeProfileID != id else { return }

        // Keep what the editors changed since the last switch.
        let liveSettings = store.loadCurrentSettings()
        if let activeIndex = current.profiles.firstIndex(where: { $0.id == current.activeProfileID }) {
            current.profiles[activeIndex].settings = liveSettings
            current.profiles[activeIndex].updatedAt = Date()
            store.saveLibrary(current)
        }

        let problems = TherapyProfileLogic.validate(
            target.settings,
            supportedBasalRates: supportedBasalRates,
            maxBasal: maxBasal
        )
        guard problems.isEmpty else { throw TherapyProfileError.invalidSettings(problems) }

        // The pump comes first. Until it has accepted the schedule, no file changes.
        if !TherapyProfileLogic.hasSameBasal(liveSettings.basal, target.settings.basal) {
            try await syncBasal(target.settings.basal)
        }

        store.saveCurrentSettings(target.settings)
        current.activeProfileID = id
        store.saveLibrary(current)

        debug(.service, "Therapy profile switched to \"\(target.name)\"")
        await applySideEffects(target.settings, basalChanged: true, othersChanged: true)
    }

    /// Replaces the basal schedule of the active profile, the same way the basal editor does.
    func applyBasalProfile(_ basal: [BasalProfileEntry]) async throws {
        var settings = store.loadCurrentSettings()
        settings.basal = basal

        let problems = TherapyProfileLogic.validate(settings, supportedBasalRates: supportedBasalRates, maxBasal: maxBasal)
            .filter { problem in
                switch problem {
                case .basalRateAboveMaxBasal,
                     .basalRateNotSupportedByPump:
                    return true
                case let .emptySchedule(category),
                     let .scheduleDoesNotStartAtMidnight(category),
                     let .scheduleNotAscending(category):
                    return category == .basal
                case let .valueOutOfRange(category, _, _):
                    return category == .basal
                }
            }
        guard problems.isEmpty else { throw TherapyProfileError.invalidSettings(problems) }

        try await syncBasal(basal)
        store.saveCurrentBasal(basal)

        var current = library()
        if let activeIndex = current.profiles.firstIndex(where: { $0.id == current.activeProfileID }) {
            current.profiles[activeIndex].settings = settings
            current.profiles[activeIndex].updatedAt = Date()
            store.saveLibrary(current)
        }

        debug(.service, "Basal schedule replaced through the therapy profile manager")
        await applySideEffects(settings, basalChanged: true, othersChanged: false)
    }

    private func syncBasal(_ basal: [BasalProfileEntry]) async throws {
        do {
            if let customBasalSync {
                try await customBasalSync(basal)
            } else {
                try await syncBasalWithPump(basal)
            }
        } catch let error as TherapyProfileError {
            throw error
        } catch {
            throw TherapyProfileError.pumpSyncFailed(error.localizedDescription)
        }
    }

    private func syncBasalWithPump(_ basal: [BasalProfileEntry]) async throws {
        guard let pump = deviceDataManager.pumpManager else { throw TherapyProfileError.noPump }
        let items = basal.map {
            RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pump.syncBasalRateSchedule(items: items) { result in
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// What the editors do after saving: tell observers, upload, and refresh the determination.
    private func applySideEffects(_ settings: TherapySettingsSnapshot, basalChanged: Bool, othersChanged: Bool) async {
        guard performsSideEffects else { return }

        if basalChanged {
            broadcaster.notify(BasalProfileObserver.self, on: .main) {
                $0.basalProfileDidChange(settings.basal)
            }
        }
        if othersChanged {
            broadcaster.notify(InsulinSensitivitiesObserver.self, on: .main) {
                $0.insulinSensitivitiesDidChange(settings.sensitivities)
            }
            broadcaster.notify(CarbRatiosObserver.self, on: .main) {
                $0.carbRatiosDidChange(settings.carbRatios)
            }
            broadcaster.notify(BGTargetsObserver.self, on: .main) {
                $0.bgTargetsDidChange(settings.targets)
            }
        }

        let nightscout = nightscoutManager
        let tidepool = tidepoolManager
        Task.detached(priority: .low) {
            do {
                try await nightscout?.uploadProfiles()
            } catch {
                debug(.nightscout, "Failed to upload therapy settings to Nightscout: \(error)")
            }
            await tidepool?.uploadSettings()
        }

        do {
            try await apsManager.determineBasalSync()
        } catch {
            debug(.service, "Determination after therapy settings change failed: \(error)")
        }
    }
}
