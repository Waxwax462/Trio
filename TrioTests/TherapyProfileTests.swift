import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

// MARK: - Fixtures

private func dec(_ string: String) -> Decimal {
    Decimal(string: string)!
}

private func isClose(_ lhs: Decimal, _ rhs: Decimal) -> Bool {
    abs(lhs - rhs) < dec("0.0001")
}

private func startString(_ minutes: Int) -> String {
    String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
}

private func makeSettings(
    basal: [(Int, String)] = [(0, "1.0")],
    sensitivity: String = "50",
    carbRatio: String = "10",
    target: String = "100"
) -> TherapySettingsSnapshot {
    TherapySettingsSnapshot(
        basal: basal.map { BasalProfileEntry(start: startString($0.0), minutes: $0.0, rate: dec($0.1)) },
        sensitivities: InsulinSensitivities(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            sensitivities: [InsulinSensitivityEntry(sensitivity: dec(sensitivity), offset: 0, start: startString(0))]
        ),
        carbRatios: CarbRatios(
            units: .grams,
            schedule: [CarbRatioEntry(start: startString(0), offset: 0, ratio: dec(carbRatio))]
        ),
        targets: BGTargets(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            targets: [BGTargetEntry(low: dec(target), high: dec(target), start: startString(0), offset: 0)]
        )
    )
}

/// Multiples of 0.05 U/hr up to 10 U/hr.
private let pumpRates: [Decimal] = (1 ... 200).map { Decimal($0) / 20 }

private final class InMemoryTherapySettingsStore: TherapySettingsStore {
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

private final class PumpRecorder: @unchecked Sendable {
    var received: [[BasalProfileEntry]] = []
    var shouldFail = false

    struct Refused: Error {}

    func sync(_ basal: [BasalProfileEntry]) async throws {
        if shouldFail { throw Refused() }
        received.append(basal)
    }
}

// MARK: - Rules

@Suite("Therapy Profile Logic Tests") struct TherapyProfileLogicTests {
    @Test("Scaling to 80% lowers basal and raises ISF and carb ratio") func testScaleDown() {
        let scaled = TherapyProfileLogic.scaled(makeSettings(), percentage: 80, supportedBasalRates: pumpRates)

        #expect(isClose(scaled.basal[0].rate, dec("0.8")))
        #expect(isClose(scaled.sensitivities.sensitivities[0].sensitivity, dec("63")))
        #expect(isClose(scaled.carbRatios.schedule[0].ratio, dec("12.5")))
        #expect(isClose(scaled.targets.targets[0].low, dec("100")), "Targets are not scaled")
    }

    @Test("Scaling to 100% changes nothing") func testScaleIdentity() {
        let original = makeSettings(basal: [(0, "0.85"), (360, "1.15")])
        let scaled = TherapyProfileLogic.scaled(original, percentage: 100, supportedBasalRates: pumpRates)
        #expect(TherapyProfileLogic.differences(from: original, to: scaled).isEmpty)
    }

    @Test("Scaled basal lands on a rate the pump supports") func testScaledBasalIsSupported() {
        let scaled = TherapyProfileLogic.scaled(
            makeSettings(basal: [(0, "0.85")]),
            percentage: 85,
            supportedBasalRates: pumpRates
        )
        // 0.85 * 0.85 = 0.7225, nearest supported rate is 0.70
        #expect(isClose(scaled.basal[0].rate, dec("0.7")))
        #expect(TherapyProfileLogic.isSupported(scaled.basal[0].rate, supportedBasalRates: pumpRates))
    }

    @Test("Basal rounding never returns zero") func testBasalRoundingFloor() {
        #expect(isClose(TherapyProfileLogic.roundedBasalRate(dec("0.01"), supportedBasalRates: nil), dec("0.05")))
        #expect(isClose(TherapyProfileLogic.roundedBasalRate(dec("0.01"), supportedBasalRates: pumpRates), dec("0.05")))
        #expect(isClose(TherapyProfileLogic.roundedBasalRate(dec("0.72"), supportedBasalRates: nil), dec("0.7")))
    }

    @Test("Percentage is limited to 50–150") func testPercentageClamp() {
        let scaled = TherapyProfileLogic.scaled(makeSettings(), percentage: 10, supportedBasalRates: pumpRates)
        #expect(isClose(scaled.basal[0].rate, dec("0.5")))
    }

    @Test("Valid settings pass validation") func testValidSettings() {
        let problems = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "0.8"), (360, "1.0")]),
            supportedBasalRates: pumpRates,
            maxBasal: 2
        )
        #expect(problems.isEmpty)
    }

    @Test("Validation finds each kind of problem") func testValidationProblems() {
        let zeroRate = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "0")]),
            supportedBasalRates: pumpRates,
            maxBasal: nil
        )
        #expect(zeroRate.contains(.valueOutOfRange(.basal, minutes: 0, value: 0)))

        let unsupported = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "0.83")]),
            supportedBasalRates: pumpRates,
            maxBasal: nil
        )
        #expect(unsupported.contains(.basalRateNotSupportedByPump(minutes: 0, value: dec("0.83"))))

        let aboveMax = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "3.0")]),
            supportedBasalRates: pumpRates,
            maxBasal: 2
        )
        #expect(aboveMax.contains(.basalRateAboveMaxBasal(minutes: 0, value: dec("3.0"))))

        let lateStart = TherapyProfileLogic.validate(
            makeSettings(basal: [(60, "1.0")]),
            supportedBasalRates: pumpRates,
            maxBasal: nil
        )
        #expect(lateStart.contains(.scheduleDoesNotStartAtMidnight(.basal)))

        let unordered = TherapyProfileLogic.validate(
            makeSettings(basal: [(0, "1.0"), (600, "1.0"), (300, "1.0")]),
            supportedBasalRates: pumpRates,
            maxBasal: nil
        )
        #expect(unordered.contains(.scheduleNotAscending(.basal)))

        var empty = makeSettings()
        empty.basal = []
        #expect(TherapyProfileLogic.validate(empty, supportedBasalRates: nil, maxBasal: nil).contains(.emptySchedule(.basal)))

        let lowSensitivity = TherapyProfileLogic.validate(
            makeSettings(sensitivity: "5"),
            supportedBasalRates: nil,
            maxBasal: nil
        )
        #expect(lowSensitivity.contains(.valueOutOfRange(.sensitivity, minutes: 0, value: 5)))
    }

    @Test("Differences list the times at which values change") func testDifferences() {
        let old = makeSettings(basal: [(0, "1.0")])
        let new = makeSettings(basal: [(0, "1.0"), (360, "0.8")], sensitivity: "60")

        let differences = TherapyProfileLogic.differences(from: old, to: new)

        #expect(differences.count == 2)
        let basal = differences.first { $0.category == .basal }
        #expect(basal?.minutes == 360)
        #expect(basal?.oldValue.map { isClose($0, dec("1.0")) } == true)
        #expect(basal?.newValue.map { isClose($0, dec("0.8")) } == true)
        #expect(differences.contains { $0.category == .sensitivity && $0.minutes == 0 })
    }

    @Test("Daily basal sums every segment") func testDailyBasal() {
        // 6 h at 1.0 + 18 h at 0.5 = 15 U
        let total = TherapyProfileLogic.dailyBasal(makeSettings(basal: [(0, "1.0"), (360, "0.5")]).basal)
        #expect(isClose(total, dec("15")))
    }
}

// MARK: - Manager

@Suite("Therapy Profile Manager Tests", .serialized) struct TherapyProfileManagerTests {
    let resolver: Resolver

    init() async throws {
        let coreDataStack = try await CoreDataStack.createForTests()
        let testContext = coreDataStack.newTaskContext()

        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext)
        ])
        resolver = assembler.resolver
    }

    private func makeManager(
        store: InMemoryTherapySettingsStore,
        pump: PumpRecorder
    ) -> BaseTherapyProfileManager {
        BaseTherapyProfileManager(
            resolver: resolver,
            store: store,
            basalSync: { try await pump.sync($0) },
            supportedBasalRates: pumpRates,
            performsSideEffects: false
        )
    }

    @Test("The first call creates one active profile from the current settings") func testInitialLibrary() {
        let store = InMemoryTherapySettingsStore(current: makeSettings(basal: [(0, "0.9")]))
        let manager = makeManager(store: store, pump: PumpRecorder())

        let library = manager.library()

        #expect(library.profiles.count == 1)
        #expect(library.activeProfileID == library.profiles.first?.id)
        #expect(library.profiles.first.map { isClose($0.settings.basal[0].rate, dec("0.9")) } == true)
        #expect(manager.library().profiles.count == 1, "A second call must not add another profile")
    }

    @Test("Activating a profile sends basal to the pump and writes the settings") func testActivate() async throws {
        let store = InMemoryTherapySettingsStore(current: makeSettings())
        let pump = PumpRecorder()
        let manager = makeManager(store: store, pump: pump)

        let camp = try manager.createProfile(name: "Training camp", basedOn: nil, percentage: 80)
        try await manager.activateProfile(id: camp.id)

        #expect(pump.received.count == 1)
        #expect(pump.received.first.map { isClose($0[0].rate, dec("0.8")) } == true)
        #expect(isClose(store.current.basal[0].rate, dec("0.8")))
        #expect(isClose(store.current.sensitivities.sensitivities[0].sensitivity, dec("63")))
        #expect(manager.library().activeProfileID == camp.id)
    }

    @Test("A pump failure leaves settings and active profile untouched") func testPumpFailure() async throws {
        let store = InMemoryTherapySettingsStore(current: makeSettings())
        let pump = PumpRecorder()
        let manager = makeManager(store: store, pump: pump)
        let originalID = manager.library().activeProfileID

        let camp = try manager.createProfile(name: "Training camp", basedOn: nil, percentage: 80)
        pump.shouldFail = true

        var thrown: TherapyProfileError?
        do {
            try await manager.activateProfile(id: camp.id)
        } catch let error as TherapyProfileError {
            thrown = error
        }

        if case .pumpSyncFailed = thrown {} else {
            Issue.record("Expected pumpSyncFailed, got \(String(describing: thrown))")
        }
        #expect(isClose(store.current.basal[0].rate, dec("1.0")))
        #expect(isClose(store.current.sensitivities.sensitivities[0].sensitivity, dec("50")))
        #expect(manager.library().activeProfileID == originalID)
    }

    @Test("Editor changes to the active profile survive switching away and back") func testRoundTrip() async throws {
        let store = InMemoryTherapySettingsStore(current: makeSettings())
        let manager = makeManager(store: store, pump: PumpRecorder())
        let standardID = try #require(manager.library().activeProfileID)
        let camp = try manager.createProfile(name: "Training camp", basedOn: nil, percentage: 80)

        // What an editor does: it writes the settings files directly.
        store.current = makeSettings(basal: [(0, "1.2")], carbRatio: "8")

        try await manager.activateProfile(id: camp.id)
        #expect(isClose(store.current.basal[0].rate, dec("0.8")))

        try await manager.activateProfile(id: standardID)
        #expect(isClose(store.current.basal[0].rate, dec("1.2")))
        #expect(isClose(store.current.carbRatios.schedule[0].ratio, dec("8")))
    }

    @Test("The pump is not contacted when basal rates are identical") func testNoPumpCallForSameBasal() async throws {
        let store = InMemoryTherapySettingsStore(current: makeSettings())
        let pump = PumpRecorder()
        let manager = makeManager(store: store, pump: pump)

        let copy = try manager.createProfile(name: "Copy", basedOn: nil, percentage: 100)
        pump.shouldFail = true
        try await manager.activateProfile(id: copy.id)

        #expect(pump.received.isEmpty)
        #expect(manager.library().activeProfileID == copy.id)
    }

    @Test("The active profile cannot be deleted and names must be unique") func testLibraryRules() throws {
        let store = InMemoryTherapySettingsStore(current: makeSettings())
        let manager = makeManager(store: store, pump: PumpRecorder())
        let activeID = try #require(manager.library().activeProfileID)

        #expect(throws: TherapyProfileError.activeProfileCannotBeDeleted) {
            try manager.deleteProfile(id: activeID)
        }

        let camp = try manager.createProfile(name: "Training camp", basedOn: nil, percentage: 90)
        #expect(throws: TherapyProfileError.nameAlreadyUsed) {
            try manager.createProfile(name: "training camp", basedOn: nil, percentage: 90)
        }
        #expect(throws: TherapyProfileError.nameMissing) {
            try manager.createProfile(name: "   ", basedOn: nil, percentage: 100)
        }

        try manager.deleteProfile(id: camp.id)
        #expect(manager.library().profiles.count == 1)
    }

    @Test("A profile with invalid values is not activated") func testInvalidProfileIsRejected() async throws {
        let store = InMemoryTherapySettingsStore(current: makeSettings())
        let pump = PumpRecorder()
        let manager = makeManager(store: store, pump: pump)
        let camp = try manager.createProfile(name: "Training camp", basedOn: nil, percentage: 80)

        // Corrupt the stored copy, as a damaged or hand-edited file would.
        var library = try #require(store.library)
        let index = try #require(library.profiles.firstIndex { $0.id == camp.id })
        library.profiles[index].settings.basal = [BasalProfileEntry(start: startString(0), minutes: 0, rate: 0)]
        store.library = library

        var rejected = false
        do {
            try await manager.activateProfile(id: camp.id)
        } catch is TherapyProfileError {
            rejected = true
        }

        #expect(rejected)
        #expect(pump.received.isEmpty)
        #expect(isClose(store.current.basal[0].rate, dec("1.0")))
    }

    @Test("Applying a basal schedule goes through the pump and updates the active profile") func testApplyBasal() async throws {
        let store = InMemoryTherapySettingsStore(current: makeSettings())
        let pump = PumpRecorder()
        let manager = makeManager(store: store, pump: pump)
        _ = manager.library()

        let newBasal = [BasalProfileEntry(start: startString(0), minutes: 0, rate: dec("0.9"))]
        try await manager.applyBasalProfile(newBasal)

        #expect(pump.received.count == 1)
        #expect(isClose(store.current.basal[0].rate, dec("0.9")))
        #expect(manager.activeProfile().map { isClose($0.settings.basal[0].rate, dec("0.9")) } == true)

        pump.shouldFail = true
        var failed = false
        do {
            try await manager.applyBasalProfile([BasalProfileEntry(start: startString(0), minutes: 0, rate: dec("0.5"))])
        } catch {
            failed = true
        }
        #expect(failed)
        #expect(isClose(store.current.basal[0].rate, dec("0.9")), "A refused schedule must not be written")
    }
}
