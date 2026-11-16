import Combine
import SwiftUI

extension AutoSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var autoSettingsManager: AutoSettingsManager!

        @Published var settings = AutoSettingsSettings()
        @Published var proposals: [AutoSettingsProposal] = []
        @Published var history: [AutoSettingsChange] = []
        @Published var lastRun: Date?
        @Published var frozenUntil: Date?
        @Published var sportFrozenUntil: Date?
        @Published var units: GlucoseUnits = .mgdL
        @Published var isWorking: Bool = false
        @Published var errorMessage: String?
        @Published var showError: Bool = false

        let limits = AutoSettingsLimits()

        override func subscribe() {
            units = settingsManager.settings.units
            reload()

            Foundation.NotificationCenter.default.publisher(for: .autoSettingsDidChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reload() }
                .store(in: &lifetime)
        }

        func reload() {
            let stored = autoSettingsManager.settings()
            if stored != settings {
                settings = stored
            }
            let state = autoSettingsManager.state()
            let now = Date()
            proposals = state.proposals
            history = state.history.reversed()
            lastRun = state.lastRun
            frozenUntil = state.frozenUntil.flatMap { $0 > now ? $0 : nil }
            sportFrozenUntil = state.sportFrozenUntil.flatMap { $0 > now ? $0 : nil }
        }

        func saveSettings() {
            guard settings != autoSettingsManager.settings() else { return }
            autoSettingsManager.saveSettings(settings)
        }

        // MARK: Actions

        func runNow() {
            guard !isWorking else { return }
            isWorking = true
            Task { [weak self] in
                guard let self else { return }
                await self.autoSettingsManager.run(now: Date())
                await MainActor.run {
                    self.isWorking = false
                    self.reload()
                }
            }
        }

        func undo(_ change: AutoSettingsChange) {
            guard !isWorking else { return }
            isWorking = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.autoSettingsManager.undo(changeID: change.id, now: Date())
                    await MainActor.run {
                        self.isWorking = false
                        self.reload()
                    }
                } catch {
                    await MainActor.run {
                        self.isWorking = false
                        self.errorMessage = error.localizedDescription
                        self.showError = true
                    }
                }
            }
        }

        func confirmBaseline() {
            autoSettingsManager.confirmBaseline()
            reload()
        }

        // MARK: Display

        func canUndo(_ change: AutoSettingsChange) -> Bool {
            change.reason == .learned && change.revertedAt == nil
        }

        func place(kind: AutoSettingKind, scopeName: String, blockStartMinute: Int) -> String {
            kind == .sportRecovery ? scopeName : TherapyProfileLogic.timeString(minutes: blockStartMinute)
        }

        func value(_ value: Double?, kind: AutoSettingKind) -> String {
            guard let value else { return "–" }
            return kind.formatted(value, units: units)
        }

        func verdictText(_ proposal: AutoSettingsProposal) -> String {
            switch proposal.verdict {
            case .notEnoughData:
                return String(localized: "Not enough data yet", comment: "Auto settings verdict")
            case .inconclusive:
                return String(localized: "The data does not agree", comment: "Auto settings verdict")
            case .matches:
                return String(localized: "Fits", comment: "Auto settings verdict")
            case .change:
                return settings.mode == .automatic
                    ? String(localized: "Step due at the next run", comment: "Auto settings verdict")
                    : String(localized: "Would change", comment: "Auto settings verdict")
            case .waiting:
                return String(localized: "Next step after the three-day pause", comment: "Auto settings verdict")
            case .atLimit:
                return String(localized: "At the edge of the allowed range", comment: "Auto settings verdict")
            case .frozen:
                return String(localized: "Paused after a low", comment: "Auto settings verdict")
            case .blocked:
                return String(localized: "Left alone after your undo", comment: "Auto settings verdict")
            case .otherKindFirst:
                return String(localized: "Waiting for another setting to settle", comment: "Auto settings verdict")
            case .notAdapted:
                return String(localized: "Set by Dynamic ISF", comment: "Auto settings verdict")
            }
        }

        func reasonText(_ change: AutoSettingsChange) -> String {
            switch change.reason {
            case .learned:
                return change.revertedAt == nil
                    ? String(localized: "Learned", comment: "Auto settings change reason")
                    : String(localized: "Learned, taken back later", comment: "Auto settings change reason")
            case .revertedAfterLow:
                return String(localized: "Taken back after a low", comment: "Auto settings change reason")
            case .undone:
                return String(localized: "Undone by you", comment: "Auto settings change reason")
            }
        }
    }
}
