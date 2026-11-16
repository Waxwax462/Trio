import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

// MARK: - Fixtures

private final class MemoryAutoSettingsStore: AutoSettingsStore {
    var settings = AutoSettingsSettings()
    var state = AutoSettingsState()

    func loadSettings() -> AutoSettingsSettings { settings }
    func saveSettings(_ settings: AutoSettingsSettings) { self.settings = settings }
    func loadState() -> AutoSettingsState { state }
    func saveState(_ state: AutoSettingsState) { self.state = state }
}

private final class MemoryTherapyStore: TherapySettingsStore {
    var current: TherapySettingsSnapshot
    var library: TherapyProfileLibrary?

    init(current: TherapySettingsSnapshot) {
        self.current = current
    }

    func loadCurrentSettings() -> TherapySettingsSnapshot { current }
    func saveCurrentSettings(_ settings: TherapySettingsSnapshot) { current = settings }
    func saveCurrentBasal(_ basal: [BasalProfileEntry]) { current.basal = basal }
    func loadLibrary() -> TherapyProfileLibrary? { library }
    func saveLibrary(_ library: TherapyProfileLibrary) { self.library = library }
}

private final class MemorySportStore: SportProfileStore {
    var profiles: [SportProfile] = []
    var run: SportProfileRun?

    func loadProfiles() -> [SportProfile] { profiles }
    func saveProfiles(_ profiles: [SportProfile]) { self.profiles = profiles }
    func loadRun() -> SportProfileRun? { run }
    func saveRun(_ run: SportProfileRun?) { self.run = run }
}

private final class FakeHistory: SettingsTestDataProvider, @unchecked Sendable {
    struct Unavailable: Error {}

    var input = BasalTestInput()
    var shouldFail = false
    var requests = 0

    func loadBasalTestInput(days _: Int, now _: Date) async throws -> BasalTestInput {
        requests += 1
        if shouldFail { throw Unavailable() }
        return input
    }
}

private final class Pump: @unchecked Sendable {
    struct Refused: Error {}

    var received: [[BasalProfileEntry]] = []
    var shouldFail = false

    func sync(_ basal: [BasalProfileEntry]) async throws {
        if shouldFail { throw Refused() }
        received.append(basal)
    }
}

private final class Messages: @unchecked Sendable {
    var bodies: [String] = []
}

private func dec(_ string: String) -> Decimal {
    Decimal(string: string)!
}

/// Runs the learner's manager against the real therapy and sport profile managers, with
/// in-memory stores, a recorded pump and a prepared history.
@Suite("Auto Settings Manager Tests", .serialized) struct AutoSettingsManagerTests {
    let resolver: Resolver
    let testContext: NSManagedObjectContext

    private let store = MemoryAutoSettingsStore()
    private let therapyStore: MemoryTherapyStore
    private let sportStore = MemorySportStore()
    private let history = FakeHistory()
    private let pump = Pump()
    private let messages = Messages()

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// 04:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86400) + 4 * 3600)

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

        therapyStore = MemoryTherapyStore(current: TherapySettingsSnapshot(
            basal: [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: dec("1.0"))],
            sensitivities: InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: [InsulinSensitivityEntry(sensitivity: 50, offset: 0, start: "00:00:00")]
            ),
            carbRatios: CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00:00", offset: 0, ratio: 10)]),
            targets: BGTargets(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                targets: [BGTargetEntry(low: 100, high: 100, start: "00:00:00", offset: 0)]
            )
        ))

        sportStore.profiles = [
            SportProfile(
                id: "ride",
                name: "Ride",
                phases: [SportPhase(id: "a", kind: .during, durationMinutes: 120, percentage: 60, target: 150, smbIsOff: true)]
            )
        ]

        // Six fasting days with level glucose, during which the loop delivered only 0.8 U/h of
        // the scheduled 1.0 U/h: the basal rate is too high.
        let start = now.addingTimeInterval(-6 * 86400)
        history.input.glucose = (0 ... 6 * 288).map {
            BasalTestGlucose(date: start.addingTimeInterval(Double($0) * 300), value: 100)
        }
        history.input.tempBasals = (-24 ..< 6 * 48).map {
            BasalTestTempBasal(
                start: start.addingTimeInterval(Double($0) * 1800),
                durationMinutes: 30,
                rate: 0.8,
                isScheduledBasal: false
            )
        }

        store.settings.mode = .automatic
    }

    // MARK: - Helpers

    private var basalRate: Decimal { therapyStore.current.basal[0].rate }

    private func makeManager() -> (manager: BaseAutoSettingsManager, sport: BaseSportProfileManager) {
        let context = testContext
        let pump = self.pump
        let messages = self.messages

        let therapy = BaseTherapyProfileManager(
            resolver: resolver,
            store: therapyStore,
            basalSync: { try await pump.sync($0) },
            supportedBasalRates: (1 ... 200).map { Decimal($0) / 20 },
            performsSideEffects: false
        )
        let sport = BaseSportProfileManager(resolver: resolver, contextProvider: { context }, store: sportStore)
        let manager = BaseAutoSettingsManager(
            resolver: resolver,
            store: store,
            dataProvider: history,
            therapyManager: therapy,
            sportManager: sport,
            environment: { AutoSettingsEnvironment(maxBasal: 5) },
            notifier: { _, body in messages.bodies.append(body) },
            calendar: calendar,
            reactsToEvents: false
        )
        return (manager, sport)
    }

    // MARK: - Tests

    @Test("In automatic mode a step is sent to the pump, saved, logged and announced") func testAutomaticRun() async throws {
        let manager = makeManager().manager

        let state = await manager.run(now: now)

        #expect(basalRate == dec("0.95"))
        #expect(pump.received.count == 1)
        #expect(pump.received.first?.first?.rate == dec("0.95"))
        #expect(state.history.count == 1)
        #expect(state.history.first?.oldValue == 1.0)
        #expect(state.history.first?.reason == .learned)
        #expect(state.lastRun == now)
        #expect(messages.bodies.count == 1)
        #expect(messages.bodies.first?.contains("0.95") == true)

        let activeProfile = try #require(therapyStore.library?.profiles.first)
        #expect(activeProfile.settings.basal[0].rate == dec("0.95"), "The active therapy profile keeps the change")
        #expect(therapyStore.current.sensitivities.sensitivities[0].sensitivity == 50, "Nothing else is touched")
    }

    @Test("In shadow mode nothing is changed") func testShadowRun() async {
        store.settings.mode = .shadow
        let manager = makeManager().manager

        let state = await manager.run(now: now)

        #expect(basalRate == dec("1.0"))
        #expect(pump.received.isEmpty)
        #expect(state.history.isEmpty)
        #expect(messages.bodies.isEmpty)

        let proposal = state.proposals.first { $0.kind == .basal }
        #expect(proposal?.verdict == .change)
        #expect(proposal?.proposed == 0.95)
    }

    @Test("Switched off, the history is not even read") func testOff() async {
        store.settings.mode = .off
        let manager = makeManager().manager

        await manager.run(now: now)
        await manager.tick(now: now)

        #expect(history.requests == 0)
        #expect(basalRate == dec("1.0"))
        #expect(store.state.lastRun == nil)
    }

    @Test("If the pump refuses, nothing is changed and nothing is logged") func testPumpRefuses() async {
        pump.shouldFail = true
        let manager = makeManager().manager

        let state = await manager.run(now: now)

        #expect(basalRate == dec("1.0"))
        #expect(state.history.isEmpty)
        #expect(messages.bodies.isEmpty)
        #expect(state.lastKnown.values.contains(1.0), "The learner still knows the old value as its own")

        // The next day the pump works again: the step is simply taken then.
        pump.shouldFail = false
        let later = await manager.run(now: now.addingTimeInterval(86400))
        #expect(basalRate == dec("0.95"))
        #expect(later.history.count == 1)
    }

    @Test("Without history nothing happens and the run is tried again") func testHistoryUnavailable() async {
        history.shouldFail = true
        let manager = makeManager().manager

        await manager.tick(now: now)
        #expect(store.state.lastRun == nil)
        #expect(basalRate == dec("1.0"))

        history.shouldFail = false
        await manager.tick(now: now.addingTimeInterval(300))
        #expect(store.state.lastRun != nil)
        #expect(basalRate == dec("0.95"))
    }

    @Test("The daily run happens once, and not before three in the morning") func testTick() async {
        let manager = makeManager().manager
        let midnight = now.addingTimeInterval(-4 * 3600)

        await manager.tick(now: midnight.addingTimeInterval(2 * 3600))
        #expect(history.requests == 0, "Too early")

        await manager.tick(now: now)
        #expect(history.requests == 1)

        await manager.tick(now: now.addingTimeInterval(300))
        await manager.tick(now: now.addingTimeInterval(12 * 3600))
        #expect(history.requests == 1, "Once a day")

        await manager.tick(now: now.addingTimeInterval(86400))
        #expect(history.requests == 2)
        #expect(basalRate == dec("0.95"), "The second run is inside the three-day pause")
    }

    @Test("The daily run waits while a sport profile is running, and logs the profile") func testTickDuringSport() async throws {
        let managers = makeManager()
        try await managers.sport.start(profileID: "ride", phaseIndex: 0)

        await managers.manager.tick(now: now)

        #expect(history.requests == 0)
        #expect(store.state.sportSpans.count == 1)
        #expect(store.state.sportSpans.first?.profileID == "ride")
        #expect(store.state.sportSpans.first?.end == nil)
        #expect(store.state.profileSpans.count == 1)

        try await managers.sport.cancel()
        await managers.manager.tick(now: now.addingTimeInterval(600))
        #expect(history.requests == 1)
        #expect(store.state.sportSpans.first?.end != nil)
    }

    @Test("Undo sets the value back through the pump and can be used once") func testUndo() async throws {
        let manager = makeManager().manager
        let state = await manager.run(now: now)
        let change = try #require(state.history.first)

        try await manager.undo(changeID: change.id, now: now.addingTimeInterval(3600))

        #expect(basalRate == dec("1.0"))
        #expect(pump.received.count == 2)
        #expect(store.state.history.count == 2)
        #expect(store.state.history.first?.revertedAt != nil)
        #expect(store.state.history.last?.reason == .undone)

        await #expect(throws: AutoSettingsError.nothingToUndo) {
            try await manager.undo(changeID: change.id, now: now.addingTimeInterval(7200))
        }

        // The value is left alone afterwards, although the data still says it is too high.
        let later = await manager.run(now: now.addingTimeInterval(5 * 86400))
        #expect(basalRate == dec("1.0"))
        #expect(later.proposals.first { $0.kind == .basal }?.verdict == .blocked)
    }

    @Test("A value edited by hand is not undone and not touched for three days") func testManualEditWins() async throws {
        let manager = makeManager().manager
        let state = await manager.run(now: now)
        let change = try #require(state.history.first)

        // The user sets another rate in the basal editor.
        therapyStore.current.basal = [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: dec("0.9"))]

        await #expect(throws: AutoSettingsError.nothingToUndo) {
            try await manager.undo(changeID: change.id, now: now.addingTimeInterval(3600))
        }
        #expect(basalRate == dec("0.9"))

        let nextDay = await manager.run(now: now.addingTimeInterval(4 * 86400))
        #expect(basalRate == dec("0.9"), "The edit counts as a change made just now")
        #expect(nextDay.proposals.first { $0.kind == .basal }?.verdict == .waiting)
        #expect(nextDay.anchors.values.contains(0.9), "The edit is the new baseline")

        _ = await manager.run(now: now.addingTimeInterval(8 * 86400))
        #expect(basalRate == dec("0.85"), "After the pause the learner continues from the edited value")
    }

    @Test("Confirming the baseline moves the band to the current values") func testConfirmBaseline() async {
        let manager = makeManager().manager
        await manager.run(now: now)
        #expect(store.state.anchors.values.contains(1.0))

        manager.confirmBaseline()

        #expect(store.state.anchors.values.contains(0.95))
        #expect(!store.state.anchors.values.contains(1.0))
    }

    @Test("The after-sport time is kept within a day") func testSettingsAreCleaned() {
        let manager = makeManager().manager
        var settings = AutoSettingsSettings()
        settings.sportAfterEffectHours = 99
        manager.saveSettings(settings)
        #expect(store.settings.sportAfterEffectHours == 24)
    }
}
