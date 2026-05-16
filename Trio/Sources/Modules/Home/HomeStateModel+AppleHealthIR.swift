import Combine
import Foundation

extension Home.StateModel {
    // MARK: - Setup

    func setupAppleHealthIR() {
        guard let service = resolver?.resolve(AppleHealthIRService.self) else { return }
        appleHealthIRService = service
        service.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let s = self.appleHealthIRService else { return }
                self.appleHealthIRMultiplier = s.insulinResistanceMultiplier
            }
            .store(in: &lifetime)
        Task { @MainActor [weak self] in
            self?.appleHealthIRMultiplier = service.insulinResistanceMultiplier
        }
    }
}
