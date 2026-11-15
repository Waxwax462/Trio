import Foundation
import Testing

@testable import Trio

@Suite("Sport Automation Logic Tests") struct SportAutomationLogicTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func minutes(_ value: Double) -> Date {
        start.addingTimeInterval(value * 60)
    }

    private let profile = SportProfile(
        id: "ride",
        name: "Ride",
        phases: [
            SportPhase(id: "a", kind: .pre, durationMinutes: 60, percentage: 80, target: 140, smbIsOff: false),
            SportPhase(id: "b", kind: .during, durationMinutes: 120, percentage: 60, target: 150, smbIsOff: true),
            SportPhase(id: "c", kind: .recovery, durationMinutes: 180, percentage: 85, target: nil, smbIsOff: false)
        ]
    )

    private func enabledSettings() -> SportAutomationSettings {
        var settings = SportAutomationSettings()
        settings.garminEnabled = true
        settings.profileID = "ride"
        return settings
    }

    private func context(run: SportProfileRun? = nil, activeOverrideID: String? = nil) -> SportAutomationContext {
        SportAutomationContext(run: run, profiles: [profile], activeOverrideID: activeOverrideID ?? run?.overrideID)
    }

    private func makeRun(phaseIndex: Int, startedAt: Date, phaseStartedAt: Date, duration: Int) -> SportProfileRun {
        SportProfileRun(
            profileID: "ride",
            profileName: "Ride",
            phaseIndex: phaseIndex,
            phaseStartedAt: phaseStartedAt,
            phaseDurationMinutes: duration,
            overrideID: "override",
            startedAt: startedAt
        )
    }

    /// State after the automation started the profile at `start`.
    private func startedState(lastSignal: Date) -> SportAutomationState {
        SportAutomationState(
            lastSignal: lastSignal,
            sessionStartedAt: start,
            sessionHandled: true,
            startedProfileID: "ride",
            startedRunAt: start
        )
    }

    // MARK: - Starting

    @Test("The first signal starts the chosen profile at the chosen phase") func testFirstSignalStarts() {
        let result = SportAutomationLogic.onSignal(
            now: start,
            settings: enabledSettings(),
            state: SportAutomationState(),
            context: context()
        )

        #expect(result.action == .start(profileID: "ride", phaseIndex: 1), "The default is to begin with the during phase")
        #expect(result.state.sessionHandled)
        #expect(result.state.startedProfileID == "ride")
        #expect(result.state.lastSignal == start)
    }

    @Test("The starting phase can be the preparation phase") func testStartPhaseChoice() {
        var settings = enabledSettings()
        settings.startPhase = .pre

        let result = SportAutomationLogic.onSignal(now: start, settings: settings, state: SportAutomationState(), context: context())

        #expect(result.action == .start(profileID: "ride", phaseIndex: 0))
    }

    @Test("Nothing starts while the automation is off, but the signal is remembered") func testDisabled() {
        var settings = enabledSettings()
        settings.garminEnabled = false

        let result = SportAutomationLogic.onSignal(now: start, settings: settings, state: SportAutomationState(), context: context())

        #expect(result.action == .none)
        #expect(result.state.lastSignal == start)
        #expect(result.state.sessionHandled == false)
    }

    @Test("An active override is never replaced") func testManualOverrideWins() {
        let result = SportAutomationLogic.onSignal(
            now: start,
            settings: enabledSettings(),
            state: SportAutomationState(),
            context: context(activeOverrideID: "manual")
        )

        #expect(result.action == .none)
        #expect(result.state.sessionHandled, "The decision is made once per activity")
        #expect(result.state.startedProfileID == nil)
    }

    @Test("A profile that is already running is left alone") func testRunningProfileNotRestarted() {
        let manual = makeRun(phaseIndex: 0, startedAt: minutes(-30), phaseStartedAt: minutes(-30), duration: 60)

        let result = SportAutomationLogic.onSignal(
            now: start,
            settings: enabledSettings(),
            state: SportAutomationState(),
            context: context(run: manual)
        )

        #expect(result.action == .none)
        #expect(result.state.startedProfileID == nil)
    }

    @Test("A missing or deleted profile starts nothing") func testMissingProfile() {
        var settings = enabledSettings()
        settings.profileID = "gone"
        let unknown = SportAutomationLogic.onSignal(now: start, settings: settings, state: SportAutomationState(), context: context())
        #expect(unknown.action == .none)

        settings.profileID = nil
        let unset = SportAutomationLogic.onSignal(now: start, settings: settings, state: SportAutomationState(), context: context())
        #expect(unset.action == .none)
    }

    @Test("A profile the user stopped is not started again in the same activity") func testNoRestartInSameActivity() {
        // Started at 0, stopped by the user, next signal five minutes later.
        let result = SportAutomationLogic.onSignal(
            now: minutes(5),
            settings: enabledSettings(),
            state: startedState(lastSignal: start),
            context: context()
        )

        #expect(result.action == .none)
    }

    @Test("A new activity after a long pause starts again") func testNewActivityStartsAgain() {
        var state = startedState(lastSignal: start)
        state.startedProfileID = nil
        state.startedRunAt = nil

        let result = SportAutomationLogic.onSignal(
            now: minutes(180),
            settings: enabledSettings(),
            state: state,
            context: context()
        )

        #expect(result.action == .start(profileID: "ride", phaseIndex: 1))
        #expect(result.state.sessionStartedAt == minutes(180))
    }

    // MARK: - Extending

    @Test("The during phase is extended while the activity goes on") func testExtend() {
        let run = makeRun(phaseIndex: 1, startedAt: start, phaseStartedAt: start, duration: 120)

        let early = SportAutomationLogic.onSignal(
            now: minutes(100),
            settings: enabledSettings(),
            state: startedState(lastSignal: minutes(95)),
            context: context(run: run)
        )
        let late = SportAutomationLogic.onSignal(
            now: minutes(115),
            settings: enabledSettings(),
            state: startedState(lastSignal: minutes(110)),
            context: context(run: run)
        )

        #expect(early.action == .none, "Twenty minutes left is enough")
        #expect(late.action == .extend(minutes: 15))
    }

    @Test("Only the during phase of the automation's own run is extended") func testExtendOnlyOwnDuringPhase() {
        let settings = enabledSettings()

        let recovery = makeRun(phaseIndex: 2, startedAt: start, phaseStartedAt: minutes(120), duration: 30)
        let inRecovery = SportAutomationLogic.onSignal(
            now: minutes(145),
            settings: settings,
            state: startedState(lastSignal: minutes(140)),
            context: context(run: recovery)
        )
        #expect(inRecovery.action == .none)

        // Same profile, but started by hand a little later.
        let manual = makeRun(phaseIndex: 1, startedAt: minutes(10), phaseStartedAt: minutes(10), duration: 30)
        let foreign = SportAutomationLogic.onSignal(
            now: minutes(35),
            settings: settings,
            state: startedState(lastSignal: minutes(30)),
            context: context(run: manual)
        )
        #expect(foreign.action == .none)

        var noExtend = settings
        noExtend.extendWhileActive = false
        let own = makeRun(phaseIndex: 1, startedAt: start, phaseStartedAt: start, duration: 30)
        let disabled = SportAutomationLogic.onSignal(
            now: minutes(25),
            settings: noExtend,
            state: startedState(lastSignal: minutes(20)),
            context: context(run: own)
        )
        #expect(disabled.action == .none)
    }

    // MARK: - Ending

    @Test("While signals keep coming, the check does nothing") func testTickDuringActivity() {
        let run = makeRun(phaseIndex: 1, startedAt: start, phaseStartedAt: start, duration: 120)
        let state = startedState(lastSignal: minutes(50))

        let result = SportAutomationLogic.onTick(now: minutes(55), settings: enabledSettings(), state: state, context: context(run: run))

        #expect(result.action == .none)
        #expect(result.state == state)
    }

    @Test("When the data field falls silent, the profile moves to recovery") func testEndMovesToRecovery() {
        let run = makeRun(phaseIndex: 1, startedAt: start, phaseStartedAt: start, duration: 120)

        let result = SportAutomationLogic.onTick(
            now: minutes(63),
            settings: enabledSettings(),
            state: startedState(lastSignal: minutes(50)),
            context: context(run: run)
        )

        #expect(result.action == .moveToPhase(2))
        #expect(result.state.startedProfileID == nil, "The activity is over; the run is no longer managed")
    }

    @Test("The end is only acted on once") func testEndOnlyOnce() {
        let run = makeRun(phaseIndex: 1, startedAt: start, phaseStartedAt: start, duration: 120)
        let first = SportAutomationLogic.onTick(
            now: minutes(63),
            settings: enabledSettings(),
            state: startedState(lastSignal: minutes(50)),
            context: context(run: run)
        )
        let second = SportAutomationLogic.onTick(
            now: minutes(68),
            settings: enabledSettings(),
            state: first.state,
            context: context(run: run)
        )
        #expect(second.action == .none)
    }

    @Test("A profile without a recovery phase is stopped at the end") func testEndWithoutRecoveryStops() {
        let short = SportProfile(id: "ride", name: "Ride", phases: Array(profile.phases.prefix(2)))
        let run = makeRun(phaseIndex: 1, startedAt: start, phaseStartedAt: start, duration: 120)

        let result = SportAutomationLogic.onTick(
            now: minutes(63),
            settings: enabledSettings(),
            state: startedState(lastSignal: minutes(50)),
            context: SportAutomationContext(run: run, profiles: [short], activeOverrideID: "override")
        )

        #expect(result.action == .stop)
    }

    @Test("At the end, a run started by hand or already in recovery is left alone") func testEndLeavesOthersAlone() {
        let settings = enabledSettings()
        let state = startedState(lastSignal: minutes(50))

        let manual = makeRun(phaseIndex: 1, startedAt: minutes(20), phaseStartedAt: minutes(20), duration: 120)
        #expect(SportAutomationLogic.onTick(now: minutes(63), settings: settings, state: state, context: context(run: manual)).action == .none)

        let recovering = makeRun(phaseIndex: 2, startedAt: start, phaseStartedAt: minutes(40), duration: 180)
        #expect(SportAutomationLogic.onTick(now: minutes(63), settings: settings, state: state, context: context(run: recovering)).action == .none)

        #expect(SportAutomationLogic.onTick(now: minutes(63), settings: settings, state: state, context: context()).action == .none)

        var keep = settings
        keep.moveToRecoveryAtEnd = false
        let own = makeRun(phaseIndex: 1, startedAt: start, phaseStartedAt: start, duration: 120)
        #expect(SportAutomationLogic.onTick(now: minutes(63), settings: keep, state: state, context: context(run: own)).action == .none)
    }

    @Test("The timeout stays within sensible limits") func testTimeoutClamp() {
        var settings = SportAutomationSettings()
        settings.endTimeoutMinutes = 1
        #expect(SportAutomationLogic.timeout(settings) == 6 * 60)
        settings.endTimeoutMinutes = 500
        #expect(SportAutomationLogic.timeout(settings) == 60 * 60)
    }
}
