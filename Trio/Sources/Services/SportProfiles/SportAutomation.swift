import Foundation

// MARK: - Models

/// How sport profiles are started without the phone.
struct SportAutomationSettings: JSON, Equatable {
    /// Start a profile when the Garmin data field becomes active.
    var garminEnabled: Bool = false
    var profileID: String?
    /// The phase to begin with. Falls back to the first phase if the profile has none of this kind.
    var startPhase: SportPhaseKind = .during
    /// Minutes without a sign of the data field after which the activity counts as over.
    var endTimeoutMinutes: Int = 12
    /// Keep the "during" phase alive for as long as the data field is active.
    var extendWhileActive: Bool = true
    /// Move to the recovery phase when the activity is over.
    var moveToRecoveryAtEnd: Bool = true
    var notify: Bool = true
}

/// What the automation remembers between signals. Stored on disk, so a restart in the middle of an
/// activity does not start a second profile.
struct SportAutomationState: JSON, Equatable {
    /// When the data field was last heard from.
    var lastSignal: Date?
    var sessionStartedAt: Date?
    /// A start has been decided for this activity, whether or not it led to a running profile.
    var sessionHandled: Bool = false
    /// The profile this automation started in the current activity.
    var startedProfileID: String?
    /// `SportProfileRun.startedAt` of that run, to tell it from a run someone started by hand.
    var startedRunAt: Date?
}

enum SportAutomationAction: Equatable {
    case none
    case start(profileID: String, phaseIndex: Int)
    case extend(minutes: Int)
    case moveToPhase(Int)
    case stop
}

/// The world as the automation sees it at one moment.
struct SportAutomationContext {
    var run: SportProfileRun?
    var profiles: [SportProfile]
    /// Any override that is active, including one of a sport profile.
    var activeOverrideID: String?
}

// MARK: - Logic

/// Decides what the automation does. Pure: the same inputs always give the same answer.
enum SportAutomationLogic {
    static let timeoutRange: ClosedRange<Int> = 6 ... 60
    /// A "during" phase with less than this left is extended while the activity goes on.
    static let extendThreshold: TimeInterval = 10 * 60
    static let extendMinutes = 15

    static func timeout(_ settings: SportAutomationSettings) -> TimeInterval {
        let minutes = min(max(settings.endTimeoutMinutes, timeoutRange.lowerBound), timeoutRange.upperBound)
        return TimeInterval(minutes) * 60
    }

    /// An activity is under way as long as signals keep arriving within the timeout.
    static func isSessionActive(state: SportAutomationState, settings: SportAutomationSettings, now: Date) -> Bool {
        guard let last = state.lastSignal else { return false }
        return now.timeIntervalSince(last) <= timeout(settings)
    }

    /// Whether the running profile is the one this automation started.
    static func owns(_ run: SportProfileRun?, state: SportAutomationState) -> Bool {
        guard let run, let profileID = state.startedProfileID, let startedAt = state.startedRunAt else { return false }
        return run.profileID == profileID && abs(run.startedAt.timeIntervalSince(startedAt)) < 1
    }

    /// The data field was heard from.
    static func onSignal(
        now: Date,
        settings: SportAutomationSettings,
        state: SportAutomationState,
        context: SportAutomationContext
    ) -> (state: SportAutomationState, action: SportAutomationAction) {
        var next = state
        if !isSessionActive(state: state, settings: settings, now: now) {
            next.sessionStartedAt = now
            next.sessionHandled = false
            next.startedProfileID = nil
            next.startedRunAt = nil
        }
        next.lastSignal = now

        guard settings.garminEnabled else { return (next, .none) }

        if !next.sessionHandled {
            // One decision per activity. If nothing is started now, nothing is started later in
            // the same activity either: a profile the user stopped stays stopped.
            next.sessionHandled = true
            guard context.run == nil,
                  context.activeOverrideID == nil,
                  let profileID = settings.profileID,
                  let profile = context.profiles.first(where: { $0.id == profileID }),
                  !profile.phases.isEmpty
            else { return (next, .none) }

            let index = profile.phases.firstIndex(where: { $0.kind == settings.startPhase }) ?? 0
            next.startedProfileID = profileID
            return (next, .start(profileID: profileID, phaseIndex: index))
        }

        if settings.extendWhileActive,
           let run = context.run,
           owns(run, state: next),
           phaseKind(of: run, in: context.profiles) == .during,
           run.phaseEndsAt.timeIntervalSince(now) < extendThreshold
        {
            return (next, .extend(minutes: extendMinutes))
        }

        return (next, .none)
    }

    /// Called regularly. Notices that the activity is over.
    static func onTick(
        now: Date,
        settings: SportAutomationSettings,
        state: SportAutomationState,
        context: SportAutomationContext
    ) -> (state: SportAutomationState, action: SportAutomationAction) {
        guard state.startedProfileID != nil,
              !isSessionActive(state: state, settings: settings, now: now)
        else { return (state, .none) }

        // The activity is over. Whatever happens next, this run is no longer extended or moved.
        var next = state
        next.startedProfileID = nil
        next.startedRunAt = nil

        guard settings.moveToRecoveryAtEnd,
              let run = context.run,
              owns(run, state: state),
              let profile = context.profiles.first(where: { $0.id == run.profileID }),
              profile.phases.indices.contains(run.phaseIndex)
        else { return (next, .none) }

        if profile.phases[run.phaseIndex].kind == .recovery {
            return (next, .none)
        }
        if let recovery = profile.phases.indices.first(where: { $0 > run.phaseIndex && profile.phases[$0].kind == .recovery }) {
            return (next, .moveToPhase(recovery))
        }
        return (next, .stop)
    }

    private static func phaseKind(of run: SportProfileRun, in profiles: [SportProfile]) -> SportPhaseKind? {
        guard let profile = profiles.first(where: { $0.id == run.profileID }),
              profile.phases.indices.contains(run.phaseIndex)
        else { return nil }
        return profile.phases[run.phaseIndex].kind
    }
}
