import Combine
import SwiftUI

extension SportProfiles {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var sportProfileManager: SportProfileManager!

        @Published var profiles: [SportProfile] = []
        @Published var run: SportProfileRun?
        @Published var units: GlucoseUnits = .mgdL
        @Published var isBusy: Bool = false
        @Published var errorMessage: String?
        @Published var showError: Bool = false

        let templates: [SportProfile] = SportProfileLogic.templates()

        override func subscribe() {
            units = settingsManager.settings.units
            reload()

            Foundation.NotificationCenter.default.publisher(for: .sportProfileRunDidChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reload() }
                .store(in: &lifetime)
        }

        func reload() {
            profiles = sportProfileManager.profiles()
            run = sportProfileManager.currentRun()
        }

        /// The phase that is running, if the profile still exists.
        var runningPhase: SportPhase? {
            guard let run, let profile = profiles.first(where: { $0.id == run.profileID }),
                  profile.phases.indices.contains(run.phaseIndex)
            else { return nil }
            return profile.phases[run.phaseIndex]
        }

        var runningPhaseCount: Int {
            guard let run else { return 0 }
            return profiles.first(where: { $0.id == run.profileID })?.phases.count ?? 0
        }

        // MARK: Profiles

        /// A copy of a template with its own identity and a name that is not taken yet.
        func draft(from template: SportProfile) -> SportProfile {
            var name = template.name
            var counter = 2
            while profiles.contains(where: { $0.name == name }) {
                name = "\(template.name) \(counter)"
                counter += 1
            }
            return SportProfile(
                id: UUID().uuidString,
                name: name,
                phases: template.phases.map { phase in
                    var copy = phase
                    copy.id = UUID().uuidString
                    return copy
                }
            )
        }

        func save(_ profile: SportProfile) -> Bool {
            do {
                try sportProfileManager.saveProfile(profile)
                reload()
                return true
            } catch {
                present(error)
                return false
            }
        }

        func delete(_ profile: SportProfile) {
            sportProfileManager.deleteProfile(id: profile.id)
            reload()
        }

        // MARK: Running

        func start(_ profile: SportProfile) {
            let id = profile.id
            perform { [weak self] in try await self?.sportProfileManager.start(profileID: id) }
        }

        func nextPhase() {
            perform { [weak self] in try await self?.sportProfileManager.skipToNextPhase() }
        }

        func extend() {
            perform { [weak self] in
                try await self?.sportProfileManager.extendCurrentPhase(byMinutes: SportProfileLogic.extensionStep)
            }
        }

        func stop() {
            perform { [weak self] in try await self?.sportProfileManager.cancel() }
        }

        private func perform(_ operation: @escaping () async throws -> Void) {
            guard !isBusy else { return }
            isBusy = true
            Task { [weak self] in
                var failure: Error?
                do {
                    try await operation()
                } catch {
                    failure = error
                }
                let caught = failure
                await MainActor.run {
                    guard let self else { return }
                    self.isBusy = false
                    self.reload()
                    if let caught {
                        self.present(caught)
                    }
                }
            }
        }

        private func present(_ error: Error) {
            errorMessage = error.localizedDescription
            showError = true
        }

        func summary(of phase: SportPhase) -> String {
            var parts = ["\(phase.durationMinutes) min", "\(Int(phase.percentage)) %"]
            if let target = phase.target {
                parts.append(target.formatted(withUnits: units))
            }
            if phase.smbIsOff {
                parts.append(String(localized: "SMBs off", comment: "Sport profile phase summary"))
            }
            return parts.joined(separator: " · ")
        }
    }
}
