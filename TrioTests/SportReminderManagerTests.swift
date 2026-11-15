import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

private final class ReminderProfileStore: SportProfileStore {
    var profiles: [SportProfile] = []
    var run: SportProfileRun?

    func loadProfiles() -> [SportProfile] { profiles }
    func saveProfiles(_ profiles: [SportProfile]) { self.profiles = profiles }
    func loadRun() -> SportProfileRun? { run }
    func saveRun(_ run: SportProfileRun?) { self.run = run }
}

private final class ReminderSettingsStore: SportReminderStore {
    var settings = SportReminderSettings()
    var state = SportReminderState()

    func loadSettings() -> SportReminderSettings { settings }
    func saveSettings(_ settings: SportReminderSettings) { self.settings = settings }
    func loadState() -> SportReminderState { state }
    func saveState(_ state: SportReminderState) { self.state = state }
}

private final class RecordingScheduler: SportReminderScheduling, @unchecked Sendable {
    var scheduled: [Date] = []
    var profileName: String?
    var messages: [String] = []

    func replaceQuestions(with dates: [Date], profileName: String?) async {
        scheduled = dates
        self.profileName = profileName
    }

    func postMessage(title: String, body _: String) {
        messages.append(title)
    }
}

/// Runs the daily question against the real sport profile manager with in-memory stores and a
/// scheduler that records instead of talking to the system.
@Suite("Sport Reminder Manager Tests", .serialized) struct SportReminderManagerTests {
    let resolver: Resolver
    let testContext: NSManagedObjectContext
    private let profileStore = ReminderProfileStore()
    private let reminderStore = ReminderSettingsStore()
    private let scheduler = RecordingScheduler()

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

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
                    SportPhase(id: "b", kind: .during, durationMinutes: 120, percentage: 60, target: 150, smbIsOff: true)
                ]
            )
        ]
        reminderStore.settings.enabled = true
        reminderStore.settings.profileID = "ride"
        reminderStore.settings.times = [7 * 60, 12 * 60]
    }

    // MARK: - Helpers

    /// Nine o'clock UTC on the current day.
    private var nineOClock: Date {
        calendar.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
    }

    private func makeManagers() -> (profiles: BaseSportProfileManager, reminder: BaseSportReminderManager) {
        let context = testContext
        let profiles = BaseSportProfileManager(resolver: resolver, contextProvider: { context }, store: profileStore)
        let reminder = BaseSportReminderManager(
            resolver: resolver,
            store: reminderStore,
            profileManager: profiles,
            scheduler: scheduler,
            calendar: calendar,
            reactsToEvents: false
        )
        return (profiles, reminder)
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

    @Test("Questions are scheduled for the rest of today and for tomorrow") func testReschedule() async {
        let managers = makeManagers()
        let now = nineOClock

        await managers.reminder.reschedule(now: now)

        #expect(scheduler.scheduled.count == 3)
        #expect(scheduler.scheduled.first == now.addingTimeInterval(3 * 3600))
        #expect(scheduler.profileName == "Ride")
    }

    @Test("\"Start now\" starts the first phase and ends the questions for today") func testStartNow() async throws {
        let managers = makeManagers()
        let now = nineOClock

        await managers.reminder.handleAnswer(.startNow, now: now)

        let run = try #require(managers.profiles.currentRun())
        #expect(run.profileID == "ride")
        #expect(run.phaseIndex == 0)
        #expect(reminderStore.state.answeredDay == SportReminderLogic.dayKey(now, calendar: calendar))
        #expect(scheduler.scheduled.count == 2, "Only tomorrow's questions remain")
        #expect(scheduler.scheduled.allSatisfy { $0 > now.addingTimeInterval(15 * 3600) })
    }

    @Test("\"Not today\" starts nothing and ends the questions for today") func testNotToday() async {
        let managers = makeManagers()
        let now = nineOClock

        await managers.reminder.handleAnswer(.notToday, now: now)

        #expect(managers.profiles.currentRun() == nil)
        #expect(scheduler.scheduled.count == 2)
        #expect(scheduler.messages.isEmpty)
    }

    @Test("\"In one hour\" starts the profile an hour later") func testStartInOneHour() async throws {
        let managers = makeManagers()
        let now = nineOClock

        await managers.reminder.handleAnswer(.startInOneHour, now: now)
        #expect(managers.profiles.currentRun() == nil)
        #expect(reminderStore.state.plannedStart == now.addingTimeInterval(3600))

        await managers.reminder.tick(now: now.addingTimeInterval(30 * 60))
        #expect(managers.profiles.currentRun() == nil, "Too early")

        await managers.reminder.tick(now: now.addingTimeInterval(62 * 60))
        #expect(managers.profiles.currentRun()?.phaseIndex == 0)
        #expect(reminderStore.state.plannedStart == nil)
    }

    @Test("A planned start does not replace a running override") func testPlannedStartSkipped() async throws {
        let managers = makeManagers()
        let now = nineOClock
        await managers.reminder.handleAnswer(.startInOneHour, now: now)
        try await activateManualOverride()

        await managers.reminder.tick(now: now.addingTimeInterval(62 * 60))

        #expect(managers.profiles.currentRun() == nil)
        #expect(reminderStore.state.plannedStart == nil, "The plan is dropped, not retried")
        #expect(scheduler.messages.count == 1)
    }

    @Test("A planned start that is long overdue is dropped silently") func testPlannedStartExpires() async {
        let managers = makeManagers()
        let now = nineOClock
        await managers.reminder.handleAnswer(.startInOneHour, now: now)

        await managers.reminder.tick(now: now.addingTimeInterval(3 * 3600))

        #expect(managers.profiles.currentRun() == nil)
        #expect(reminderStore.state.plannedStart == nil)
        #expect(scheduler.messages.isEmpty)
    }

    @Test("Without a chosen profile an answer starts nothing and says why") func testMissingProfile() async {
        reminderStore.settings.profileID = nil
        let managers = makeManagers()

        await managers.reminder.handleAnswer(.startNow, now: nineOClock)

        #expect(managers.profiles.currentRun() == nil)
        #expect(scheduler.messages.count == 1)
    }

    @Test("With the question off nothing is scheduled") func testDisabled() async {
        reminderStore.settings.enabled = false
        let managers = makeManagers()

        await managers.reminder.reschedule(now: nineOClock)

        #expect(scheduler.scheduled.isEmpty)
    }

    @Test("While a sport profile runs there are no questions today") func testNoQuestionsWhileRunning() async throws {
        let managers = makeManagers()
        let now = nineOClock
        try await managers.profiles.start(profileID: "ride", phaseIndex: 0)

        await managers.reminder.reschedule(now: now)

        #expect(scheduler.scheduled.count == 2)
        #expect(scheduler.scheduled.allSatisfy { $0 > now.addingTimeInterval(15 * 3600) })
    }
}
