import AppIntents
import Foundation

/// Starts a sport profile from the Shortcuts app, for example from the automation
/// "When I start a workout on Apple Watch".
struct StartSportProfileIntent: AppIntent {
    static var title = LocalizedStringResource("Start a sport profile")

    static var description = IntentDescription(.init("Start a sport profile"))

    @Parameter(
        title: LocalizedStringResource("Sport Profile"),
        description: LocalizedStringResource("Sport profile choice"),
        requestValueDialog: IntentDialog(stringLiteral: String(localized: "Which sport profile do you want to start?"))
    ) var profile: SportProfileEntity?

    @Parameter(
        title: LocalizedStringResource("Skip preparation phase"),
        description: LocalizedStringResource("If toggled, the profile begins with its sport phase"),
        default: true
    ) var skipPreparation: Bool

    @Parameter(
        title: LocalizedStringResource("Confirm Before applying"),
        description: LocalizedStringResource("If toggled, you will need to confirm before applying"),
        default: false
    ) var confirmBeforeApplying: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Start sport profile \(\.$profile)") {
            \.$skipPreparation
            \.$confirmBeforeApplying
        }
    }

    @MainActor func perform() async throws -> some ProvidesDialog {
        let chosen: SportProfileEntity
        if let profile {
            chosen = profile
        } else {
            chosen = try await $profile.requestDisambiguation(
                among: SportProfileIntentRequest.allProfiles(),
                dialog: IntentDialog(stringLiteral: String(localized: "Select sport profile"))
            )
        }

        let name: String = chosen.name

        if confirmBeforeApplying {
            try await requestConfirmation(
                result: .result(
                    dialog: IntentDialog(stringLiteral: String(localized: "Confirm to start sport profile '\(name)'"))
                )
            )
        }

        if await SportProfileIntentRequest.start(chosen, skipPreparation: skipPreparation) {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Sport profile '\(name)' started")))
        } else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Sport profile '\(name)' failed")))
        }
    }
}

/// Moves the running sport profile to its next phase, for example when a workout ends.
struct NextSportProfilePhaseIntent: AppIntent {
    static var title = LocalizedStringResource("Next sport profile phase")

    static var description = IntentDescription(.init("Move the running sport profile to its next phase"))

    @MainActor func perform() async throws -> some ProvidesDialog {
        if await SportProfileIntentRequest.nextPhase() {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Sport profile moved to the next phase")))
        } else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "No sport profile is running")))
        }
    }
}

/// Ends the running sport profile and its override.
struct StopSportProfileIntent: AppIntent {
    static var title = LocalizedStringResource("Stop sport profile")

    static var description = IntentDescription(.init("Stop the running sport profile"))

    @MainActor func perform() async throws -> some ProvidesDialog {
        if await SportProfileIntentRequest.stop() {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Sport profile stopped")))
        } else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "No sport profile is running")))
        }
    }
}
