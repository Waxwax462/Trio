import Foundation
import Testing

@testable import Trio

@Suite("Sport Profile Logic Tests") struct SportProfileLogicTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeProfile(durations: [Int] = [60, 90, 120]) -> SportProfile {
        let kinds: [SportPhaseKind] = [.pre, .during, .recovery]
        return SportProfile(
            id: "profile",
            name: "Run",
            phases: durations.enumerated().map { index, minutes in
                SportPhase(
                    id: "phase-\(index)",
                    kind: kinds[index % kinds.count],
                    durationMinutes: minutes,
                    percentage: 80,
                    target: 140,
                    smbIsOff: true
                )
            }
        )
    }

    private func makeRun(phaseIndex: Int = 0, duration: Int = 60) -> SportProfileRun {
        SportProfileRun(
            profileID: "profile",
            profileName: "Run",
            phaseIndex: phaseIndex,
            phaseStartedAt: start,
            phaseDurationMinutes: duration,
            overrideID: "override-1",
            startedAt: start
        )
    }

    private func minutes(_ value: Double) -> Date {
        start.addingTimeInterval(value * 60)
    }

    // MARK: - Decisions

    @Test("A phase that is still running is kept") func testKeep() {
        let decision = SportProfileLogic.decide(
            run: makeRun(),
            profile: makeProfile(),
            activeOverrideID: "override-1",
            now: minutes(30)
        )
        #expect(decision == .keep)
    }

    @Test("A phase that reached its end advances to the next one") func testAdvance() {
        let decision = SportProfileLogic.decide(
            run: makeRun(),
            profile: makeProfile(),
            activeOverrideID: "override-1",
            now: minutes(61)
        )
        #expect(decision == .advance(toPhase: 1))
    }

    @Test("The check may close a phase shortly before its nominal end") func testAdvanceLead() {
        let profile = makeProfile()
        let justInsideLead = SportProfileLogic.decide(
            run: makeRun(),
            profile: profile,
            activeOverrideID: "override-1",
            now: minutes(58)
        )
        let beforeLead = SportProfileLogic.decide(
            run: makeRun(),
            profile: profile,
            activeOverrideID: "override-1",
            now: minutes(55)
        )
        #expect(justInsideLead == .advance(toPhase: 1))
        #expect(beforeLead == .keep)
    }

    @Test("After the last phase the profile finishes") func testFinish() {
        let decision = SportProfileLogic.decide(
            run: makeRun(phaseIndex: 2, duration: 120),
            profile: makeProfile(),
            activeOverrideID: "override-1",
            now: minutes(121)
        )
        #expect(decision == .finish)
    }

    @Test("A different override means someone took over") func testAbandonOnForeignOverride() {
        let early = SportProfileLogic.decide(
            run: makeRun(),
            profile: makeProfile(),
            activeOverrideID: "something-else",
            now: minutes(30)
        )
        let late = SportProfileLogic.decide(
            run: makeRun(),
            profile: makeProfile(),
            activeOverrideID: "something-else",
            now: minutes(90)
        )
        #expect(early == .abandon)
        #expect(late == .abandon, "A foreign override is never replaced, even when the phase is over")
    }

    @Test("A cancelled override ends the profile") func testAbandonOnCancel() {
        let decision = SportProfileLogic.decide(
            run: makeRun(),
            profile: makeProfile(),
            activeOverrideID: nil,
            now: minutes(30)
        )
        #expect(decision == .abandon)
    }

    @Test("An override that already expired still lets the profile move on") func testAdvanceAfterExpiry() {
        let decision = SportProfileLogic.decide(
            run: makeRun(),
            profile: makeProfile(),
            activeOverrideID: nil,
            now: minutes(70)
        )
        #expect(decision == .advance(toPhase: 1))
    }

    @Test("A deleted profile or an impossible phase index ends the run") func testAbandonOnMissingProfile() {
        let missing = SportProfileLogic.decide(run: makeRun(), profile: nil, activeOverrideID: "override-1", now: minutes(10))
        let outOfRange = SportProfileLogic.decide(
            run: makeRun(phaseIndex: 7),
            profile: makeProfile(),
            activeOverrideID: "override-1",
            now: minutes(10)
        )
        #expect(missing == .abandon)
        #expect(outOfRange == .abandon)
    }

    // MARK: - Limits

    @Test("Values outside the allowed range are pulled back") func testSanitize() throws {
        var profile = makeProfile()
        profile.name = "  Long run  "
        profile.phases[0].durationMinutes = 1
        profile.phases[0].percentage = 150
        profile.phases[0].target = 60
        profile.phases[1].durationMinutes = 5000
        profile.phases[1].percentage = 0
        profile.phases[1].target = nil

        let cleaned = try #require(SportProfileLogic.sanitized(profile))

        #expect(cleaned.name == "Long run")
        #expect(cleaned.phases[0].durationMinutes == SportProfileLogic.durationRange.lowerBound)
        #expect(cleaned.phases[0].percentage == 100, "A sport profile never increases insulin")
        #expect(cleaned.phases[0].target == 100)
        #expect(cleaned.phases[1].durationMinutes == SportProfileLogic.durationRange.upperBound)
        #expect(cleaned.phases[1].percentage == 10)
        #expect(cleaned.phases[1].target == nil)
    }

    @Test("A profile without a name or without phases is rejected") func testSanitizeRejects() {
        var unnamed = makeProfile()
        unnamed.name = "   "
        var empty = makeProfile()
        empty.phases = []

        #expect(SportProfileLogic.sanitized(unnamed) == nil)
        #expect(SportProfileLogic.sanitized(empty) == nil)
    }

    @Test("Every template is valid as it is and only reduces insulin") func testTemplates() {
        let templates = SportProfileLogic.templates()
        #expect(templates.count == 5)

        for template in templates {
            #expect(SportProfileLogic.sanitized(template) == template, "\(template.name) must already be within limits")
            #expect(template.phases.map(\.kind) == [.pre, .during, .recovery])
            #expect(template.phases.allSatisfy { $0.percentage <= 100 })
        }
        #expect(Set(templates.map(\.id)).count == templates.count)
    }

    @Test("The override name carries profile and phase") func testOverrideName() {
        let profile = makeProfile()
        #expect(SportProfileLogic.overrideName(profileName: profile.name, phase: profile.phases[1]) == "Run – Sport")
    }
}
