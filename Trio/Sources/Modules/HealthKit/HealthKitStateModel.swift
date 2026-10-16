import Combine
import SwiftUI

extension AppleHealthKit {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var healthKitManager: HealthKitManager!

        @Published var units: GlucoseUnits = .mgdL
        @Published var useAppleHealth = false
        @Published var needShowInformationTextForSetPermissions = false
        @Published var workoutRecoveryAutomationEnabled = false
        @Published var workoutRecoveryBasalPercentage = 80
        @Published var workoutRecoveryDurationMinutes = 120
        @Published var workoutRecoveryAutomationError: String?
        @Published var isUpdatingWorkoutRecoveryAutomation = false

        override func subscribe() {
            units = settingsManager.settings.units

            useAppleHealth = settingsManager.settings.useAppleHealth
            workoutRecoveryAutomationEnabled = settingsManager.settings.workoutRecoveryAutomationEnabled
            workoutRecoveryBasalPercentage = settingsManager.settings.workoutRecoveryBasalPercentage
            workoutRecoveryDurationMinutes = settingsManager.settings.workoutRecoveryDurationMinutes

            needShowInformationTextForSetPermissions = healthKitManager.hasGrantedFullWritePermissions

            subscribeSetting(\.useAppleHealth, on: $useAppleHealth) {
                useAppleHealth = $0
            } didSet: { [weak self] value in
                guard let self = self else { return }

                guard value else {
                    self.needShowInformationTextForSetPermissions = false
                    return
                }

                Task {
                    do {
                        let permissionGranted = try await self.healthKitManager.requestPermission()

                        await MainActor.run {
                            self.needShowInformationTextForSetPermissions = !self.healthKitManager.hasGlucoseWritePermission()
                        }

                        if permissionGranted {
                            debug(.service, "Permission granted for HealthKitManager")
                        } else {
                            warning(.service, "Permission not granted for HealthKitManager")
                        }
                    } catch {
                        warning(.service, "Error requesting permission for HealthKitManager", error: error)
                    }
                }
            }

            subscribeSetting(\.workoutRecoveryBasalPercentage, on: $workoutRecoveryBasalPercentage) {
                workoutRecoveryBasalPercentage = $0
            }

            subscribeSetting(\.workoutRecoveryDurationMinutes, on: $workoutRecoveryDurationMinutes) {
                workoutRecoveryDurationMinutes = $0
            }

            subscribeSetting(\.workoutRecoveryAutomationEnabled, on: $workoutRecoveryAutomationEnabled) {
                workoutRecoveryAutomationEnabled = $0
            } didSet: { [weak self] enabled in
                guard let self else { return }
                Task {
                    await MainActor.run {
                        self.isUpdatingWorkoutRecoveryAutomation = true
                    }
                    do {
                        try await self.healthKitManager.setWorkoutRecoveryAutomationEnabled(enabled)
                        await MainActor.run {
                            self.workoutRecoveryAutomationError = nil
                            self.isUpdatingWorkoutRecoveryAutomation = false
                        }
                    } catch {
                        var settings = self.settingsManager.settings
                        settings.workoutRecoveryAutomationEnabled = false
                        self.settingsManager.settings = settings
                        await MainActor.run {
                            self.workoutRecoveryAutomationEnabled = false
                            self.workoutRecoveryAutomationError = error.localizedDescription
                            self.isUpdatingWorkoutRecoveryAutomation = false
                        }
                    }
                }
            }
        }
    }
}

extension AppleHealthKit.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
        workoutRecoveryAutomationEnabled = settingsManager.settings.workoutRecoveryAutomationEnabled
        workoutRecoveryBasalPercentage = settingsManager.settings.workoutRecoveryBasalPercentage
        workoutRecoveryDurationMinutes = settingsManager.settings.workoutRecoveryDurationMinutes
    }
}
