import SwiftUI

extension TherapyProfiles {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var profileManager: TherapyProfileManager!

        @Published var profiles: [TherapyProfile] = []
        @Published var activeProfileID: String?
        @Published var units: GlucoseUnits = .mgdL
        @Published var isSwitching: Bool = false
        @Published var errorMessage: String?
        @Published var showError: Bool = false

        override func subscribe() {
            units = settingsManager.settings.units
            reload()
        }

        func reload() {
            let library = profileManager.library()
            let live = profileManager.currentSettings()
            // The active profile is shown with what is in effect right now.
            profiles = library.profiles.map { profile in
                guard profile.id == library.activeProfileID else { return profile }
                var current = profile
                current.settings = live
                return current
            }
            activeProfileID = library.activeProfileID
        }

        func differences(to profile: TherapyProfile) -> [TherapyProfileDifference] {
            profileManager.differences(toProfile: profile.id)
        }

        func create(name: String, basedOn sourceID: String?, percentage: Decimal) -> Bool {
            do {
                try profileManager.createProfile(name: name, basedOn: sourceID, percentage: percentage)
                reload()
                return true
            } catch {
                present(error)
                return false
            }
        }

        func rename(_ profile: TherapyProfile, to name: String) -> Bool {
            do {
                try profileManager.renameProfile(id: profile.id, to: name)
                reload()
                return true
            } catch {
                present(error)
                return false
            }
        }

        func delete(_ profile: TherapyProfile) {
            do {
                try profileManager.deleteProfile(id: profile.id)
                reload()
            } catch {
                present(error)
            }
        }

        func activate(_ profile: TherapyProfile) {
            guard !isSwitching else { return }
            isSwitching = true
            let id = profile.id
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.profileManager.activateProfile(id: id)
                    await MainActor.run {
                        self.isSwitching = false
                        self.reload()
                    }
                } catch {
                    await MainActor.run {
                        self.isSwitching = false
                        self.reload()
                        self.present(error)
                    }
                }
            }
        }

        private func present(_ error: Error) {
            errorMessage = error.localizedDescription
            showError = true
        }

        func formatted(_ value: Decimal?, category: TherapySettingCategory) -> String {
            guard let value else { return "–" }
            switch category {
            case .basal:
                return "\(value.description) " + String(localized: "U/hr", comment: "Units per hour")
            case .carbRatio:
                return "\(value.description) " + String(localized: "g/U", comment: "Grams per unit")
            case .sensitivity,
                 .target:
                return value.formatted(withUnits: units)
            }
        }
    }
}
