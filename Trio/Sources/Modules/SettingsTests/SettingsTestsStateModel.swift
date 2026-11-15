import SwiftUI

extension SettingsTests {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var dataProvider: SettingsTestDataProvider!
        @Injected() private var profileManager: TherapyProfileManager!

        @Published var results: [BasalBlockResult] = []
        @Published var hasAnalyzed: Bool = false
        @Published var isWorking: Bool = false
        @Published var errorMessage: String?
        @Published var showError: Bool = false

        let config = BasalTestConfig()

        // MARK: Analysis

        func analyze() {
            guard !isWorking else { return }
            isWorking = true
            let rates = profileManager.supportedBasalRates?.map { Double($0) }
            let config = self.config

            Task { [weak self] in
                guard let self else { return }
                do {
                    let input = try await self.dataProvider.loadBasalTestInput(days: SettingsTests.Config.lookbackDays, now: Date())
                    let results = BasalTestEvaluator.evaluate(input, config: config, supportedBasalRates: rates)
                    await MainActor.run {
                        self.results = results
                        self.hasAnalyzed = true
                        self.isWorking = false
                    }
                } catch {
                    await MainActor.run {
                        self.isWorking = false
                        self.present(error)
                    }
                }
            }
        }

        // MARK: Applying a suggestion

        /// Writes the suggested rate of one time block into the basal schedule. The schedule goes
        /// to the pump first, exactly as when it is saved in the basal editor.
        func apply(_ result: BasalBlockResult) {
            guard !isWorking, let proposedRate = result.proposedRate else { return }
            guard let rate = Decimal(string: String(format: "%.3f", proposedRate)) else { return }

            let basal = profileManager.currentSettings().basal.map { entry in
                entry.minutes == result.blockStartMinute
                    ? BasalProfileEntry(start: entry.start, minutes: entry.minutes, rate: rate)
                    : entry
            }

            isWorking = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.profileManager.applyBasalProfile(basal)
                    await MainActor.run {
                        self.isWorking = false
                        self.analyze()
                    }
                } catch {
                    await MainActor.run {
                        self.isWorking = false
                        self.present(error)
                    }
                }
            }
        }

        private func present(_ error: Error) {
            errorMessage = error.localizedDescription
            showError = true
        }

        // MARK: Display

        func timeRange(_ result: BasalBlockResult) -> String {
            let start = TherapyProfileLogic.timeString(minutes: result.blockStartMinute)
            let end = TherapyProfileLogic.timeString(minutes: result.blockEndMinute % (24 * 60))
            return "\(start) – \(end)"
        }

        func rate(_ value: Double?) -> String {
            guard let value else { return "–" }
            return String(format: "%.2f", value) + " " + String(localized: "U/hr", comment: "Units per hour")
        }

        func verdictText(_ result: BasalBlockResult) -> String {
            switch result.verdict {
            case .notEnoughData:
                return String(
                    localized: "Not enough undisturbed data (\(result.windows.count) of \(config.minWindows) windows).",
                    comment: "Basal check verdict"
                )
            case .inconclusive:
                return String(localized: "The windows do not agree. No suggestion.", comment: "Basal check verdict")
            case .matches:
                return String(localized: "The scheduled rate fits.", comment: "Basal check verdict")
            case .raise:
                return String(localized: "More basal insulin was needed.", comment: "Basal check verdict")
            case .lower:
                return String(localized: "Less basal insulin was needed.", comment: "Basal check verdict")
            }
        }
    }
}
