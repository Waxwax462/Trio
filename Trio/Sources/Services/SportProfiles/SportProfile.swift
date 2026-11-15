import Foundation

// MARK: - Models

enum SportPhaseKind: String, JSON, CaseIterable {
    case pre
    case during
    case recovery
}

/// One step of a sport profile. While it runs it is an ordinary override with these values.
struct SportPhase: JSON, Identifiable, Equatable {
    var id: String
    var kind: SportPhaseKind
    /// How long the phase lasts. It ends earlier when the user moves on to the next phase.
    var durationMinutes: Int
    /// Insulin delivery in percent of the profile, 100 = unchanged.
    var percentage: Double
    /// Glucose target in mg/dL; `nil` keeps the profile target.
    var target: Decimal?
    var smbIsOff: Bool
}

struct SportProfile: JSON, Identifiable, Equatable {
    var id: String
    var name: String
    var phases: [SportPhase]
}

/// The profile that is running right now. Stored on disk so it survives an app restart.
struct SportProfileRun: JSON, Equatable {
    var profileID: String
    var profileName: String
    var phaseIndex: Int
    var phaseStartedAt: Date
    var phaseDurationMinutes: Int
    /// `OverrideStored.id` of the override that carries the current phase.
    var overrideID: String
    var startedAt: Date

    var phaseEndsAt: Date {
        phaseStartedAt.addingTimeInterval(TimeInterval(phaseDurationMinutes) * 60)
    }
}

/// What to do with a running profile at a given moment.
enum SportRunDecision: Equatable {
    /// The current phase is still running.
    case keep
    case advance(toPhase: Int)
    /// The last phase is over.
    case finish
    /// Someone else changed the override, so the profile no longer applies.
    case abandon
}

// MARK: - Logic

/// Pure rules for sport profiles. No storage and no Core Data.
enum SportProfileLogic {
    /// A phase may be closed this much before its nominal end. The check runs once per loop
    /// cycle, so without the lead a phase would regularly overrun by a full cycle.
    static let advanceLead: TimeInterval = 150

    static let durationRange: ClosedRange<Int> = 10 ... 720
    /// Sport profiles only ever reduce insulin delivery.
    static let percentageRange: ClosedRange<Double> = 10 ... 100
    static let targetRange: ClosedRange<Decimal> = 100 ... 180
    static let extensionStep = 15

    static func decide(
        run: SportProfileRun,
        profile: SportProfile?,
        activeOverrideID: String?,
        now: Date
    ) -> SportRunDecision {
        guard let profile, profile.phases.indices.contains(run.phaseIndex) else { return .abandon }

        let isDue = now >= run.phaseEndsAt.addingTimeInterval(-advanceLead)

        if let activeOverrideID {
            // A different override is running: the user or another source took over.
            guard activeOverrideID == run.overrideID else { return .abandon }
        } else if !isDue {
            // Nothing is running although the phase should be: it was cancelled.
            return .abandon
        }

        guard isDue else { return .keep }

        let next = run.phaseIndex + 1
        return next < profile.phases.count ? .advance(toPhase: next) : .finish
    }

    /// Brings every value into the allowed range and drops profiles without phases to `nil`.
    static func sanitized(_ profile: SportProfile) -> SportProfile? {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !profile.phases.isEmpty else { return nil }

        let phases = profile.phases.map { phase -> SportPhase in
            var cleaned = phase
            cleaned.durationMinutes = min(max(phase.durationMinutes, durationRange.lowerBound), durationRange.upperBound)
            cleaned.percentage = min(max(phase.percentage, percentageRange.lowerBound), percentageRange.upperBound)
            if let target = phase.target {
                cleaned.target = min(max(target, targetRange.lowerBound), targetRange.upperBound)
            }
            return cleaned
        }
        return SportProfile(id: profile.id, name: name, phases: phases)
    }

    static func overrideName(profileName: String, phase: SportPhase) -> String {
        "\(profileName) – \(phase.kind.shortName)"
    }

    // MARK: Templates

    /// Starting points for new profiles. The values are conservative assumptions, not medical
    /// advice; every one of them is meant to be adjusted by the user.
    static func templates() -> [SportProfile] {
        [
            template(
                "Endurance",
                pre: (60, 80, 140, true),
                during: (120, 60, 150, true),
                recovery: (180, 85, 120, false)
            ),
            template(
                "Intervals",
                pre: (30, 90, 130, false),
                during: (60, 90, 140, true),
                recovery: (240, 85, 120, false)
            ),
            template(
                "Strength",
                pre: (30, 100, 120, false),
                during: (90, 100, 130, true),
                recovery: (180, 90, 115, false)
            ),
            template(
                "Competition",
                pre: (60, 90, 130, false),
                during: (180, 100, 140, true),
                recovery: (360, 80, 120, false)
            ),
            template(
                "Long Day",
                pre: (60, 80, 140, true),
                during: (480, 65, 140, true),
                recovery: (480, 80, 120, false)
            )
        ]
    }

    private static func template(
        _ name: String,
        pre: (Int, Double, Int, Bool),
        during: (Int, Double, Int, Bool),
        recovery: (Int, Double, Int, Bool)
    ) -> SportProfile {
        func phase(_ kind: SportPhaseKind, _ values: (Int, Double, Int, Bool)) -> SportPhase {
            SportPhase(
                id: UUID().uuidString,
                kind: kind,
                durationMinutes: values.0,
                percentage: values.1,
                target: Decimal(values.2),
                smbIsOff: values.3
            )
        }
        return SportProfile(
            id: UUID().uuidString,
            name: name,
            phases: [phase(.pre, pre), phase(.during, during), phase(.recovery, recovery)]
        )
    }
}

extension SportPhaseKind {
    /// Used in override names, which are stored and uploaded, so it is not localized.
    var shortName: String {
        switch self {
        case .pre: return "Pre"
        case .during: return "Sport"
        case .recovery: return "Recovery"
        }
    }
}
