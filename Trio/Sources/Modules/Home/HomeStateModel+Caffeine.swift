import Combine
import Foundation

extension Home.StateModel {
    // MARK: - Setup

    func setupCaffeine() {
        guard let service = resolver?.resolve(CaffeineService.self) else { return }
        caffeineService = service
        service.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let s = self.caffeineService else { return }
                self.currentCaffeineMg = s.currentMg
                self.caffeineIRMultiplier = s.insulinResistanceMultiplier
            }
            .store(in: &lifetime)
        Task { @MainActor [weak self] in
            self?.currentCaffeineMg = service.currentMg
            self?.caffeineIRMultiplier = service.insulinResistanceMultiplier
        }
    }
}
