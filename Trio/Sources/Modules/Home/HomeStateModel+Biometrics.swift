import Combine
import Foundation

extension Home.StateModel {
    func setupBiometrics() {
        guard let service = resolver?.resolve(BiometricsService.self) else { return }
        biometricsService = service
        service.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let s = self.biometricsService else { return }
                self.stepCount = s.stepCount
                self.hrv = s.hrv
                self.sleepHours = s.sleepHours
                self.exerciseHours = s.exerciseHours
                self.biometricsAuthStatus = s.authorizationStatus
                self.appleHealthIRService?.update(
                    sleepHours: s.sleepHours, stepCount: s.stepCount,
                    hrv: s.hrv, exerciseHours: s.exerciseHours
                )
            }
            .store(in: &lifetime)
        Task { @MainActor [weak self] in
            guard let self, let s = self.biometricsService else { return }
            self.stepCount = s.stepCount
            self.hrv = s.hrv
            self.sleepHours = s.sleepHours
            self.biometricsAuthStatus = s.authorizationStatus
            self.appleHealthIRService?.update(sleepHours: s.sleepHours, stepCount: s.stepCount, hrv: s.hrv, exerciseHours: s.exerciseHours)
        }
    }

    func startBiometrics() {
        biometricsService?.startMonitoring()
    }

    func stopBiometrics() {
        biometricsService?.stopMonitoring()
    }

    func refreshBiometricsSleep() {
        biometricsService?.refreshSleep()
    }
}
