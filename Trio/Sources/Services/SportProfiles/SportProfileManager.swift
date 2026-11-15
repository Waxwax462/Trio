import CoreData
import Foundation
import Swinject

extension Notification.Name {
    /// Posted whenever the running sport profile starts, changes phase or ends.
    static let sportProfileRunDidChange = Notification.Name("sportProfileRunDidChange")
}

// MARK: - Storage seam

protocol SportProfileStore {
    func loadProfiles() -> [SportProfile]
    func saveProfiles(_ profiles: [SportProfile])
    func loadRun() -> SportProfileRun?
    func saveRun(_ run: SportProfileRun?)
}

final class FileSportProfileStore: SportProfileStore {
    private let storage: FileStorage

    init(storage: FileStorage) {
        self.storage = storage
    }

    func loadProfiles() -> [SportProfile] {
        storage.retrieve(OpenAPS.Trio.sportProfiles, as: [SportProfile].self) ?? []
    }

    func saveProfiles(_ profiles: [SportProfile]) {
        storage.save(profiles, as: OpenAPS.Trio.sportProfiles)
    }

    func loadRun() -> SportProfileRun? {
        storage.retrieve(OpenAPS.Trio.sportProfileRun, as: SportProfileRun.self)
    }

    func saveRun(_ run: SportProfileRun?) {
        if let run {
            storage.save(run, as: OpenAPS.Trio.sportProfileRun)
        } else {
            storage.remove(OpenAPS.Trio.sportProfileRun)
        }
    }
}

// MARK: - Errors

enum SportProfileError: LocalizedError, Equatable {
    case profileNotFound
    case invalidProfile
    case nothingRunning

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return String(localized: "The sport profile no longer exists.", comment: "Sport profile error")
        case .invalidProfile:
            return String(
                localized: "A sport profile needs a name and at least one phase.",
                comment: "Sport profile error"
            )
        case .nothingRunning:
            return String(localized: "No sport profile is running.", comment: "Sport profile error")
        }
    }
}

// MARK: - Manager

/// Runs sport profiles: a plan of phases, each of which is an ordinary override while it lasts.
///
/// The manager creates one override per phase and activates it through `AdjustmentManager`, so
/// the algorithm, the home screen, the history and Nightscout see nothing but overrides. Phase
/// changes are checked after every determination, which keeps them working in the background.
/// When anything else changes the override, the profile stops: manual input always wins.
protocol SportProfileManager {
    func profiles() -> [SportProfile]
    func saveProfile(_ profile: SportProfile) throws
    func deleteProfile(id: String)
    func currentRun() -> SportProfileRun?
    /// Starts a profile at the given phase; earlier phases are skipped.
    func start(profileID: String, phaseIndex: Int) async throws
    func skipToNextPhase() async throws
    /// Moves the running profile to a later phase.
    func jumpToPhase(_ index: Int) async throws
    /// `OverrideStored.id` of the override that is active right now, whoever set it.
    func activeOverrideID() async -> String?
    func extendCurrentPhase(byMinutes minutes: Int) async throws
    func cancel() async throws
    func tick(now: Date) async
}

extension SportProfileManager {
    func start(profileID: String) async throws {
        try await start(profileID: profileID, phaseIndex: 0)
    }
}

final class BaseSportProfileManager: SportProfileManager, Injectable, @unchecked Sendable {
    @Injected() private var storage: FileStorage!
    @Injected() private var adjustmentManager: AdjustmentManager!
    @Injected() private var broadcaster: Broadcaster!

    private let customStore: SportProfileStore?
    private let makeContext: () -> NSManagedObjectContext
    private let queue = SportProfileQueue()

    init(
        resolver: Resolver,
        contextProvider: (() -> NSManagedObjectContext)? = nil,
        store: SportProfileStore? = nil
    ) {
        makeContext = contextProvider ?? { CoreDataStack.shared.newTaskContext() }
        customStore = store
        injectServices(resolver)
        broadcaster.register(DeterminationObserver.self, observer: self)
    }

    private var store: SportProfileStore {
        customStore ?? FileSportProfileStore(storage: storage)
    }

    // MARK: Profiles

    func profiles() -> [SportProfile] {
        store.loadProfiles()
    }

    func saveProfile(_ profile: SportProfile) throws {
        guard let cleaned = SportProfileLogic.sanitized(profile) else { throw SportProfileError.invalidProfile }
        var all = store.loadProfiles()
        if let index = all.firstIndex(where: { $0.id == cleaned.id }) {
            all[index] = cleaned
        } else {
            all.append(cleaned)
        }
        store.saveProfiles(all)
    }

    func deleteProfile(id: String) {
        var all = store.loadProfiles()
        all.removeAll { $0.id == id }
        store.saveProfiles(all)
    }

    func currentRun() -> SportProfileRun? {
        store.loadRun()
    }

    // MARK: Running

    func start(profileID: String, phaseIndex: Int) async throws {
        try await queue.run { [self] in
            guard let profile = store.loadProfiles().first(where: { $0.id == profileID }),
                  let cleaned = SportProfileLogic.sanitized(profile)
            else { throw SportProfileError.profileNotFound }
            let index = cleaned.phases.indices.contains(phaseIndex) ? phaseIndex : 0
            try await startPhase(index, of: cleaned, runStartedAt: Date())
        }
    }

    func jumpToPhase(_ index: Int) async throws {
        try await queue.run { [self] in
            guard let run = store.loadRun() else { throw SportProfileError.nothingRunning }
            guard let profile = store.loadProfiles().first(where: { $0.id == run.profileID }),
                  let cleaned = SportProfileLogic.sanitized(profile),
                  cleaned.phases.indices.contains(index),
                  index > run.phaseIndex
            else { throw SportProfileError.profileNotFound }
            try await startPhase(index, of: cleaned, runStartedAt: run.startedAt)
        }
    }

    func skipToNextPhase() async throws {
        try await queue.run { [self] in
            guard let run = store.loadRun() else { throw SportProfileError.nothingRunning }
            guard let profile = store.loadProfiles().first(where: { $0.id == run.profileID }),
                  let cleaned = SportProfileLogic.sanitized(profile)
            else {
                try await finish(run: run, cancelOverride: true)
                return
            }
            let next = run.phaseIndex + 1
            if next < cleaned.phases.count {
                try await startPhase(next, of: cleaned, runStartedAt: run.startedAt)
            } else {
                try await finish(run: run, cancelOverride: true)
            }
        }
    }

    func extendCurrentPhase(byMinutes minutes: Int) async throws {
        try await queue.run { [self] in
            guard var run = store.loadRun() else { throw SportProfileError.nothingRunning }
            let extended = min(run.phaseDurationMinutes + max(minutes, 0), SportProfileLogic.durationRange.upperBound)
            guard extended != run.phaseDurationMinutes else { return }

            try await updateOverrideDuration(id: run.overrideID, minutes: extended)
            run.phaseDurationMinutes = extended
            store.saveRun(run)
            Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
            announceChange()
        }
    }

    func cancel() async throws {
        try await queue.run { [self] in
            guard let run = store.loadRun() else { throw SportProfileError.nothingRunning }
            try await finish(run: run, cancelOverride: true)
        }
    }

    /// Checks whether the current phase is over and moves on. Safe to call at any time.
    func tick(now: Date) async {
        do {
            try await queue.run { [self] in
                guard let run = store.loadRun() else { return }
                let profile = store.loadProfiles()
                    .first(where: { $0.id == run.profileID })
                    .flatMap(SportProfileLogic.sanitized)
                let activeID = await activeOverrideID()

                switch SportProfileLogic.decide(run: run, profile: profile, activeOverrideID: activeID, now: now) {
                case .keep:
                    return
                case .abandon:
                    debug(.service, "Sport profile \"\(run.profileName)\" stopped: the override was changed elsewhere")
                    store.saveRun(nil)
                    announceChange()
                case let .advance(next):
                    guard let profile else { return }
                    try await startPhase(next, of: profile, runStartedAt: run.startedAt)
                case .finish:
                    try await finish(run: run, cancelOverride: activeID == run.overrideID)
                }
            }
        } catch {
            debug(.service, "Sport profile check failed: \(error)")
        }
    }

    // MARK: Steps

    private func startPhase(_ index: Int, of profile: SportProfile, runStartedAt: Date) async throws {
        let phase = profile.phases[index]
        let now = Date()
        let created = try await createOverride(
            name: SportProfileLogic.overrideName(profileName: profile.name, phase: phase),
            phase: phase,
            date: now
        )
        try await adjustmentManager.activateOverride(.objectID(created.objectID), source: .sportProfile)

        store.saveRun(
            SportProfileRun(
                profileID: profile.id,
                profileName: profile.name,
                phaseIndex: index,
                phaseStartedAt: now,
                phaseDurationMinutes: phase.durationMinutes,
                overrideID: created.id,
                startedAt: runStartedAt
            )
        )
        debug(.service, "Sport profile \"\(profile.name)\": phase \(index + 1) of \(profile.phases.count) started")
        announceChange()
    }

    private func finish(run: SportProfileRun, cancelOverride: Bool) async throws {
        store.saveRun(nil)
        announceChange()
        guard cancelOverride else { return }
        // Only end the override if it is still the one this profile started.
        guard await activeOverrideID() == run.overrideID else { return }
        do {
            try await adjustmentManager.cancelOverride(source: .sportProfile)
        } catch AdjustmentError.nothingActive {
            // Already gone, which is the state we want.
        }
        debug(.service, "Sport profile \"\(run.profileName)\" ended")
    }

    private func announceChange() {
        Foundation.NotificationCenter.default.post(name: .sportProfileRunDidChange, object: nil)
    }

    // MARK: Core Data

    private func createOverride(
        name: String,
        phase: SportPhase,
        date: Date
    ) async throws -> (objectID: NSManagedObjectID, id: String) {
        let context = makeContext()
        context.name = "sportProfileCreateOverride"

        return try await context.perform {
            let row = OverrideStored(context: context)
            let id = UUID().uuidString
            row.id = id
            row.name = name
            row.date = date
            row.isPreset = false
            row.isUploadedToNS = false
            row.enabled = false
            row.duration = NSDecimalNumber(value: phase.durationMinutes)
            row.indefinite = false
            row.percentage = phase.percentage
            row.isfAndCr = true
            row.isf = true
            row.cr = true
            row.smbIsOff = phase.smbIsOff
            row.smbIsScheduledOff = false
            row.advancedSettings = false
            row.target = (phase.target ?? 0) as NSDecimalNumber

            try context.obtainPermanentIDs(for: [row])
            try context.save()
            return (objectID: row.objectID, id: id)
        }
    }

    private func updateOverrideDuration(id: String, minutes: Int) async throws {
        let context = makeContext()
        context.name = "sportProfileExtendOverride"

        try await context.perform {
            let request = NSFetchRequest<OverrideStored>(entityName: "OverrideStored")
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            guard let row = try context.fetch(request).first else { return }
            row.duration = NSDecimalNumber(value: minutes)
            row.isUploadedToNS = false
            try context.save()
        }
    }

    func activeOverrideID() async -> String? {
        let context = makeContext()
        context.name = "sportProfileActiveOverride"

        return await context.perform {
            let request = NSFetchRequest<OverrideStored>(entityName: "OverrideStored")
            request.predicate = NSPredicate.lastActiveOverride
            request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            request.fetchLimit = 1
            return (try? context.fetch(request))?.first?.id
        }
    }
}

extension BaseSportProfileManager: DeterminationObserver {
    func determinationDidUpdate(_: Determination) {
        Task { [weak self] in
            await self?.tick(now: Date())
        }
    }
}

// MARK: - Serialization

/// Runs sport profile operations one after another. The periodic check and the user's taps arrive
/// independently, and each of them reads the run, changes the override and writes the run back.
private actor SportProfileQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable() async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
