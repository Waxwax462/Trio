import Combine
import Foundation

// MARK: - Protocol

protocol CaffeineService: AnyObject {
    /// All logged entries, newest first.
    var entries: [CaffeineEntry] { get }
    /// Current active caffeine level in mg (accounting for half-life decay).
    var currentMg: Double { get }
    /// Insulin resistance multiplier: 1.0 = no effect, 1.30 = 30% increase.
    var insulinResistanceMultiplier: Double { get }
    /// Fires whenever entries or derived values change.
    var updatePublisher: AnyPublisher<Void, Never> { get }

    func log(mg: Double, source: CaffeineSource)
    func remove(id: UUID)
}

// MARK: - Implementation

final class BaseCaffeineService: CaffeineService {
    private(set) var entries: [CaffeineEntry] = []
    private(set) var currentMg: Double = 0
    private(set) var insulinResistanceMultiplier: Double = 1.0

    var updatePublisher: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private let subject = PassthroughSubject<Void, Never>()
    private let storageKey = "CaffeineEntries"
    // Biological half-life ≈ 5.5 h; insulin-resistance effect window: 12 h
    private let halfLifeHours: Double = 5.5
    private let activeWindowHours: Double = 12

    init() {
        load()
        recompute()
    }

    // MARK: - Public

    func log(mg: Double, source: CaffeineSource) {
        guard mg > 0 else { return }
        entries.insert(CaffeineEntry(mg: mg, source: source), at: 0)
        prune()
        recompute()
        save()
        subject.send()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        recompute()
        save()
        subject.send()
    }

    // MARK: - Math

    private func recompute() {
        let now = Date()
        currentMg = entries.reduce(0.0) { total, entry in
            let elapsedHours = now.timeIntervalSince(entry.timestamp) / 3600
            // Exponential decay: C(t) = C0 * 0.5^(t / halfLife)
            return total + entry.mg * pow(0.5, elapsedHours / halfLifeHours)
        }
        // Up to 30% IR increase at 300 mg; capped there
        let factor = min(currentMg / 300.0, 1.0) * 0.30
        insulinResistanceMultiplier = 1.0 + factor
    }

    // MARK: - Persistence (UserDefaults JSON)

    private func prune() {
        let cutoff = Date().addingTimeInterval(-activeWindowHours * 3600)
        entries = entries.filter { $0.timestamp > cutoff }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CaffeineEntry].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-activeWindowHours * 3600)
        entries = decoded.filter { $0.timestamp > cutoff }
    }
}
