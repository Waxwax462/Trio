import Combine
import Foundation

extension Home.StateModel {
    // MARK: - Setup

    func setupHeartRate() {
        guard let service = resolver?.resolve(HeartRateService.self) else { return }
        hrService = service
        service.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let s = self.hrService else { return }
                self.currentBPM = s.currentBPM
                self.isHRStale = s.isStale
                self.hrStressPoints = s.stressPoints
                self.hrAuthorizationStatus = s.authorizationStatus
            }
            .store(in: &lifetime)
        Task {
            do {
                try await service.start()
            } catch HeartRateServiceError.authorizationDenied {
                debug(.service, "HeartRateService: HealthKit authorization denied")
            } catch HeartRateServiceError.healthKitUnavailable {
                debug(.service, "HeartRateService: HealthKit not available on this device")
            } catch {
                debug(.service, "HeartRateService start error: \(error.localizedDescription)")
            }
        }
    }

    func stopHeartRate() {
        hrService?.stop()
    }
}
