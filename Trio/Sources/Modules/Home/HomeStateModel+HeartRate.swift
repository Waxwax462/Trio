import Combine
import Foundation

extension Home.StateModel {
    // MARK: - Setup (call once at launch)

    func setupHeartRate() {
        // Guard: service already wired up — don't create duplicate subscriptions.
        guard hrService == nil, let service = resolver?.resolve(HeartRateService.self) else { return }
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
        startHeartRate()
    }

    // MARK: - Start / Stop (safe to call on every foreground / background transition)

    func startHeartRate() {
        guard let service = hrService else { return }
        Task {
            do {
                try await service.start()
            } catch HeartRateServiceError.healthKitUnavailable {
                debug(.service, "HeartRateService: HealthKit not available on this device")
            } catch {
                debug(.service, "HeartRateService start error: \(error.localizedDescription)")
            }
        }
    }

    func stopHeartRate() { hrService?.stop() }
}
