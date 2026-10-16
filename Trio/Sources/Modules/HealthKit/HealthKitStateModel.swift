import Combine
import CoreData
import HealthKit
import SwiftUI

extension AppleHealthKit {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var healthKitManager: HealthKitManager!
        @Injected() private var tempTargetStorage: TempTargetsStorage!

        @Published var units: GlucoseUnits = .mgdL
        @Published var useAppleHealth = false
        @Published var needShowInformationTextForSetPermissions = false
        @Published var activityTempTargetAutomationEnabled = false
        @Published var activityTempTargetRules: [String: String] = [:]
        @Published var tempTargetPresets: [TempTargetStored] = []
        @Published var activityAutomationError: String?
        @Published var isUpdatingActivityAutomation = false

        private let viewContext = CoreDataStack.shared.persistentContainer.viewContext

        override func subscribe() {
            units = settingsManager.settings.units

            useAppleHealth = settingsManager.settings.useAppleHealth
            activityTempTargetRules = settingsManager.settings.activityTempTargetRules

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

            subscribeSetting(\.activityTempTargetAutomationEnabled, on: $activityTempTargetAutomationEnabled) {
                activityTempTargetAutomationEnabled = $0
            } didSet: { [weak self] enabled in
                guard let self else { return }
                Task {
                    await MainActor.run {
                        self.isUpdatingActivityAutomation = true
                    }
                    do {
                        try await self.healthKitManager.setActivityTempTargetAutomationEnabled(enabled)
                        await MainActor.run {
                            self.activityAutomationError = nil
                            self.isUpdatingActivityAutomation = false
                        }
                    } catch {
                        var settings = self.settingsManager.settings
                        settings.activityTempTargetAutomationEnabled = false
                        self.settingsManager.settings = settings
                        await MainActor.run {
                            self.activityTempTargetAutomationEnabled = false
                            self.activityAutomationError = error.localizedDescription
                            self.isUpdatingActivityAutomation = false
                        }
                    }
                }
            }

            loadTempTargetPresets()
        }

        func setTempTargetPreset(_ presetID: String, for activity: AppleHealthWorkoutActivity) {
            var settings = settingsManager.settings
            if presetID.isEmpty {
                settings.activityTempTargetRules.removeValue(forKey: activity.id)
            } else {
                settings.activityTempTargetRules[activity.id] = presetID
            }
            settingsManager.settings = settings
            activityTempTargetRules = settings.activityTempTargetRules
        }

        private func loadTempTargetPresets() {
            Task {
                do {
                    let ids = try await tempTargetStorage.fetchForTempTargetPresets()
                    await MainActor.run {
                        tempTargetPresets = ids.compactMap {
                            try? viewContext.existingObject(with: $0) as? TempTargetStored
                        }
                    }
                } catch {
                    debug(.service, "Failed to load Temp Target presets for activity rules: \(error)")
                }
            }
        }
    }
}

extension AppleHealthKit.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
        activityTempTargetAutomationEnabled = settingsManager.settings.activityTempTargetAutomationEnabled
        activityTempTargetRules = settingsManager.settings.activityTempTargetRules
    }
}

struct AppleHealthWorkoutActivity: Identifiable {
    let type: HKWorkoutActivityType
    let title: String

    var id: String { String(type.rawValue) }

    static let common: [AppleHealthWorkoutActivity] = [
        .init(type: .walking, title: String(localized: "Walking")),
        .init(type: .running, title: String(localized: "Running")),
        .init(type: .cycling, title: String(localized: "Cycling")),
        .init(type: .hiking, title: String(localized: "Hiking")),
        .init(type: .swimming, title: String(localized: "Swimming")),
        .init(type: .rowing, title: String(localized: "Rowing")),
        .init(type: .elliptical, title: String(localized: "Elliptical")),
        .init(type: .traditionalStrengthTraining, title: String(localized: "Traditional Strength Training")),
        .init(type: .functionalStrengthTraining, title: String(localized: "Functional Strength Training")),
        .init(type: .highIntensityIntervalTraining, title: String(localized: "High-Intensity Interval Training")),
        .init(type: .yoga, title: String(localized: "Yoga")),
        .init(type: .dance, title: String(localized: "Dance")),
        .init(type: .other, title: String(localized: "Other"))
    ]
}
