import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

private final class InMemorySportProfileStore: SportProfileStore {
    var profiles: [SportProfile] = []
    var run: SportProfileRun?

    func loadProfiles() -> [SportProfile] { profiles }
    func saveProfiles(_ profiles: [SportProfile]) { self.profiles = profiles }
    func loadRun() -> SportProfileRun? { run }
    func saveRun(_ run: SportProfileRun?) { self.run = run }
}

private struct OverrideSnapshot {
    let id: String?
    let name: String?
    let percentage: Double
    let duration: Decimal?
    let target: Decimal?
    let smbIsOff: Bool
}

/// Runs a sport profile against the real `AdjustmentManager` and an in-memory Core Data store.
/// The determination step is stubbed out in `TestAssembly`.
@Suite("Sport Profile Manager Tests", .serialized) struct SportProfileManagerTests {
    let resolver: Resolver
    let testContext: NSManagedObjectContext
    private let store = InMemorySportProfileStore()

    init() async throws {
        let coreDataStack = try await CoreDataStack.createForTests()
        let context = coreDataStack.newTaskContext()
        testContext = context

        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: context)
        ])
        resolver = assembler.resolver
    }

    // MARK: - Helpers

    private func makeManager() -> BaseSportProfileManager {
        let context = testContext
        return BaseSportProfileManager(resolver: resolver, contextProvider: { context }, store: store)
    }

    private func makeProfile() -> SportProfile {
        SportProfile(
            id: "run",
            name: "Run",
            phases: [
                SportPhase(id: "a", kind: .pre, durationMinutes: 60, percentage: 80, target: 140, smbIsOff: false),
                SportPhase(id: "b", kind: .during, durationMinutes: 90, percentage: 60, target: 150, smbIsOff: true),
                SportPhase(id: "c", kind: .recovery, durationMinutes: 120, percentage: 85, target: nil, smbIsOff: false)
            ]
        )
    }

    private func enabledOverrides() async -> [OverrideSnapshot] {
        let context = testContext
        return await context.perform {
            let request = NSFetchRequest<OverrideStored>(entityName: "OverrideStored")
            request.predicate = NSPredicate(format: "enabled == %@", true as NSNumber)
            let rows = (try? context.fetch(request)) ?? []
            return rows.map {
                OverrideSnapshot(
                    id: $0.id,
                    name: $0.name,
                    percentage: $0.percentage,
                    duration: $0.duration?.decimalValue,
                    target: $0.target?.decimalValue,
                    smbIsOff: $0.smbIsOff
                )
            }
        }
    }

    private func runEntryCount() async -> Int {
        let context = testContext
        return await context.perform {
            let request = NSFetchRequest<OverrideRunStored>(entityName: "OverrideRunStored")
            return (try? context.count(for: request)) ?? 0
        }
    }

    /// An override that does not belong to any sport profile, activated the way a preset would be.
    private func activateForeignOverride() async throws {
        let context = testContext
        let objectID = try await context.perform {
            let row = OverrideStored(context: context)
            row.id = UUID().uuidString
            row.name = "Manual"
            row.date = Date()
            row.isPreset = false
            row.enabled = false
            row.indefinite = true
            row.percentage = 120
            row.duration = 0
            row.target = 0
            try context.obtainPermanentIDs(for: [row])
            try context.save()
            return row.objectID
        }
        let adjustmentManager = try #require(resolver.resolve(AdjustmentManager.self))
        try await adjustmentManager.activateOverride(.objectID(objectID), source: .app)
    }

    // MARK: - Tests

    @Test("Starting a profile activates the first phase as an override") func testStart() async throws {
        let manager = makeManager()
        try manager.saveProfile(makeProfile())

        try await manager.start(profileID: "run")

        let run = try #require(manager.currentRun())
        #expect(run.phaseIndex == 0)
        #expect(run.phaseDurationMinutes == 60)

        let active = await enabledOverrides()
        #expect(active.count == 1)
        let override = try #require(active.first)
        #expect(override.id == run.overrideID)
        #expect(override.name == "Run – Pre")
        #expect(override.percentage == 80)
        #expect(override.duration == 60)
        #expect(override.target == 140)
        #expect(override.smbIsOff == false)
    }

    @Test("When a phase is over, the next one replaces it") func testAdvance() async throws {
        let manager = makeManager()
        try manager.saveProfile(makeProfile())
        try await manager.start(profileID: "run")
        let firstOverrideID = try #require(manager.currentRun()?.overrideID)

        await manager.tick(now: Date().addingTimeInterval(30 * 60))
        #expect(manager.currentRun()?.phaseIndex == 0, "Nothing changes while the phase runs")

        await manager.tick(now: Date().addingTimeInterval(61 * 60))

        let run = try #require(manager.currentRun())
        #expect(run.phaseIndex == 1)
        #expect(run.overrideID != firstOverrideID)

        let active = await enabledOverrides()
        #expect(active.count == 1, "Exactly one override is active after a phase change")
        #expect(active.first?.id == run.overrideID)
        #expect(active.first?.percentage == 60)
        #expect(active.first?.smbIsOff == true)
        let recordedRuns = await runEntryCount()
        #expect(recordedRuns == 1, "The finished phase is recorded as a run")
    }

    @Test("A phase without its own target leaves the target alone") func testPhaseWithoutTarget() async throws {
        let manager = makeManager()
        try manager.saveProfile(makeProfile())
        try await manager.start(profileID: "run")
        try await manager.skipToNextPhase()
        try await manager.skipToNextPhase()

        #expect(manager.currentRun()?.phaseIndex == 2)
        let active = await enabledOverrides()
        #expect(active.first?.target == 0, "Zero is how an override says: keep the profile target")
    }

    @Test("Skipping past the last phase ends the profile and its override") func testSkipToEnd() async throws {
        let manager = makeManager()
        try manager.saveProfile(makeProfile())
        try await manager.start(profileID: "run")

        try await manager.skipToNextPhase()
        try await manager.skipToNextPhase()
        try await manager.skipToNextPhase()

        #expect(manager.currentRun() == nil)
        let remaining = await enabledOverrides()
        #expect(remaining.isEmpty)
    }

    @Test("The last phase running out ends the profile") func testFinishByTime() async throws {
        let manager = makeManager()
        try manager.saveProfile(makeProfile())
        try await manager.start(profileID: "run")
        try await manager.skipToNextPhase()
        try await manager.skipToNextPhase()

        await manager.tick(now: Date().addingTimeInterval(121 * 60))

        #expect(manager.currentRun() == nil)
        let remaining = await enabledOverrides()
        #expect(remaining.isEmpty)
    }

    @Test("Cancelling ends the profile and its override") func testCancel() async throws {
        let manager = makeManager()
        try manager.saveProfile(makeProfile())
        try await manager.start(profileID: "run")

        try await manager.cancel()

        #expect(manager.currentRun() == nil)
        let remaining = await enabledOverrides()
        #expect(remaining.isEmpty)
    }

    @Test("An override set by someone else stops the profile and stays untouched") func testForeignOverrideWins() async throws {
        let manager = makeManager()
        try manager.saveProfile(makeProfile())
        try await manager.start(profileID: "run")

        try await activateForeignOverride()
        await manager.tick(now: Date().addingTimeInterval(61 * 60))

        #expect(manager.currentRun() == nil)
        let active = await enabledOverrides()
        #expect(active.count == 1)
        #expect(active.first?.name == "Manual")
        #expect(active.first?.percentage == 120)
    }

    @Test("Extending a phase lengthens the run and the override") func testExtend() async throws {
        let manager = makeManager()
        try manager.saveProfile(makeProfile())
        try await manager.start(profileID: "run")

        try await manager.extendCurrentPhase(byMinutes: 15)

        #expect(manager.currentRun()?.phaseDurationMinutes == 75)
        let extended = await enabledOverrides()
        #expect(extended.first?.duration == 75)

        await manager.tick(now: Date().addingTimeInterval(65 * 60))
        #expect(manager.currentRun()?.phaseIndex == 0, "The extended phase is still running after its original end")
    }

    @Test("A restart in the middle of a phase continues where it was") func testRestart() async throws {
        let first = makeManager()
        try first.saveProfile(makeProfile())
        try await first.start(profileID: "run")

        // A new manager on the same store is what the app has after a restart.
        let second = makeManager()
        await second.tick(now: Date().addingTimeInterval(10 * 60))
        #expect(second.currentRun()?.phaseIndex == 0)

        await second.tick(now: Date().addingTimeInterval(61 * 60))
        #expect(second.currentRun()?.phaseIndex == 1)
        let afterRestart = await enabledOverrides()
        #expect(afterRestart.count == 1)
    }

    @Test("Starting an unknown profile fails without side effects") func testStartUnknown() async throws {
        let manager = makeManager()

        await #expect(throws: SportProfileError.profileNotFound) {
            try await manager.start(profileID: "missing")
        }
        #expect(manager.currentRun() == nil)
        let remaining = await enabledOverrides()
        #expect(remaining.isEmpty)
    }

    @Test("Saving clamps values so a profile can only reduce insulin") func testSaveSanitizes() throws {
        let manager = makeManager()
        var profile = makeProfile()
        profile.phases[0].percentage = 180

        try manager.saveProfile(profile)

        #expect(manager.profiles().first?.phases[0].percentage == 100)
        #expect(throws: SportProfileError.invalidProfile) {
            try manager.saveProfile(SportProfile(id: "x", name: "", phases: []))
        }
    }
}
