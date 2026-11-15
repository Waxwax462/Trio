import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

private final class AutomationProfileStore: SportProfileStore {
    var profiles: [SportProfile] = []
    var run: SportProfileRun?

    func loadProfiles() -> [SportProfile] { profiles }
    func saveProfiles(_ profiles: [SportProfile]) { self.profiles = profiles }
    func loadRun() -> SportProfileRun? { run }
    func saveRun(_ run: SportProfileRun?) { self.run = run }
}

private final class AutomationSettingsStore: SportAutomationStore {
    var settings = SportAutomationSettings()
    var state = SportAutomationState()

    func loadSettings() -> SportAutomationSettings { settings }
    func saveSettings(_ settings: SportAutomationSettings) { self.settings = settings }
    func loadState() -> SportAutomationState { state }
    func saveState(_ state: SportAutomationState) { self.state = state }
}

private final class NotificationRecorder: @unchecked Sendable {
    var titles: [String] = []
}

/// Drives the automation against the real sport profile manager and adjustment manager, with
/// in-memory stores. Signals are passed in with explicit times.
@Suite("Sport Automation Manager Tests", .serialized) struct SportAutomationManagerTests {
    let resolver: Resolver
    let testContext: NSManagedObjectContext
    private let profileStore = AutomationProfileStore()
    private let automationStore = AutomationSettingsStore()
    private let notifications = NotificationRecorder()

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

        profileStore.profiles = [
            SportProfile(
                id: "ride",
                name: "Ride",
                phases: [
                    SportPhase(id: "a", kind: .pre, durationMinutes: 60, percentage: 80, target: 140, smbIsOff: false),
                    SportPhase(id: "b", kind: .during, durationMinutes: 10, percentage: 60, target: 150, smbIsOff: true),
                    SportPhase(id: "c", kind: .recovery, durationMinutes: 180, percentage: 85, target: nil, smbIsOff: false)
                ]
            )
        ]
        automationStore.settings.garminEnabled = true
        automationStore.settings.profileID = "ride"
    }

    // MARK: - Helpers

    private func makeManagers() -> (profiles: BaseSportProfileManager, automation: BaseSportAutomationManager) {
        let context = testContext
        let recorder = notifications
        let profiles = BaseSportProfileManager(resolver: resolver, contextProvider: { context }, store: profileStore)
        let automation = BaseSportAutomationManager(
            resolver: resolver,
            store: automationStore,
            profileManager: profiles,
            notifier: { title, _ in recorder.titles.append(title) }
        )
        return (profiles, automation)
    }

    private func enabledOverrideCount() async -> Int {
        let context = testContext
        return await context.perform {
            let request = NSFetchRequest<OverrideStored>(entityName: "OverrideStored")
            request.predicate = NSPredicate(format: "enabled == %@", true as NSNumber)
            return (try? context.count(for: request)) ?? 0
        }
    }

    private func activateManualOverride() async throws {
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

    @Test("The first signal starts the profile at its sport phase") func testSignalStarts() async throws {
        let managers = makeManagers()
        let now = Date()

        await managers.automation.handleGarminSignal(now: now)

        let run = try #require(managers.profiles.currentRun())
        #expect(run.profileID == "ride")
        #expect(run.phaseIndex == 1)
        let active = await enabledOverrideCount()
        #expect(active == 1)
        #expect(automationStore.state.startedProfileID == "ride")
        #expect(automationStore.state.startedRunAt != nil)
        #expect(notifications.titles.count == 1)
    }

    @Test("When the signals stop, the profile moves to recovery") func testSilenceMovesToRecovery() async throws {
        let managers = makeManagers()
        let now = Date()
        await managers.automation.handleGarminSignal(now: now)

        await managers.automation.tick(now: now.addingTimeInterval(5 * 60))
        #expect(managers.profiles.currentRun()?.phaseIndex == 1, "Five minutes of silence is within the timeout")

        await managers.automation.tick(now: now.addingTimeInterval(13 * 60))

        #expect(managers.profiles.currentRun()?.phaseIndex == 2)
        let active = await enabledOverrideCount()
        #expect(active == 1)
        #expect(automationStore.state.startedProfileID == nil)
        #expect(notifications.titles.count == 2)
    }

    @Test("Signals near the end of the sport phase extend it") func testSignalExtends() async throws {
        let managers = makeManagers()
        let now = Date()
        await managers.automation.handleGarminSignal(now: now)
        #expect(managers.profiles.currentRun()?.phaseDurationMinutes == 10)

        await managers.automation.handleGarminSignal(now: now.addingTimeInterval(5 * 60))

        #expect(managers.profiles.currentRun()?.phaseIndex == 1)
        #expect(managers.profiles.currentRun()?.phaseDurationMinutes == 25)
    }

    @Test("A manual override blocks the automatic start") func testManualOverrideBlocks() async throws {
        let managers = makeManagers()
        try await activateManualOverride()

        await managers.automation.handleGarminSignal(now: Date())

        #expect(managers.profiles.currentRun() == nil)
        let active = await enabledOverrideCount()
        #expect(active == 1, "The manual override is still the only one")
        #expect(notifications.titles.isEmpty)
    }

    @Test("A profile the user stopped is not restarted during the same activity") func testNoRestartAfterStop() async throws {
        let managers = makeManagers()
        let now = Date()
        await managers.automation.handleGarminSignal(now: now)
        try await managers.profiles.cancel()

        await managers.automation.handleGarminSignal(now: now.addingTimeInterval(5 * 60))
        await managers.automation.handleGarminSignal(now: now.addingTimeInterval(10 * 60))

        #expect(managers.profiles.currentRun() == nil)
        let active = await enabledOverrideCount()
        #expect(active == 0)
    }

    @Test("A profile started by hand is not moved when signals stop") func testManualRunUntouched() async throws {
        let managers = makeManagers()
        let now = Date()
        // The automation starts and the user replaces its run with one started by hand.
        await managers.automation.handleGarminSignal(now: now)
        try await managers.profiles.cancel()
        try await managers.profiles.start(profileID: "ride", phaseIndex: 0)
        var run = try #require(profileStore.run)
        run.startedAt = now.addingTimeInterval(120)
        profileStore.run = run

        await managers.automation.tick(now: now.addingTimeInterval(20 * 60))

        #expect(managers.profiles.currentRun()?.phaseIndex == 0)
    }

    @Test("With the automation off, signals are only recorded") func testDisabled() async throws {
        automationStore.settings.garminEnabled = false
        let managers = makeManagers()
        let now = Date()

        await managers.automation.handleGarminSignal(now: now)

        #expect(managers.profiles.currentRun() == nil)
        #expect(automationStore.state.lastSignal != nil)
        let active = await enabledOverrideCount()
        #expect(active == 0)
    }

    @Test("Saving settings keeps the timeout within limits") func testSaveSettingsClamps() {
        let managers = makeManagers()
        var settings = managers.automation.settings()
        settings.endTimeoutMinutes = 1

        managers.automation.saveSettings(settings)

        #expect(managers.automation.settings().endTimeoutMinutes == SportAutomationLogic.timeoutRange.lowerBound)
    }
}
