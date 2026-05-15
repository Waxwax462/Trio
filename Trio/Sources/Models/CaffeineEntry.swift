import Foundation

struct CaffeineEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let mg: Double
    let source: CaffeineSource

    init(id: UUID = UUID(), timestamp: Date = Date(), mg: Double, source: CaffeineSource) {
        self.id = id
        self.timestamp = timestamp
        self.mg = mg
        self.source = source
    }
}

enum CaffeineSource: String, Codable, CaseIterable, Sendable {
    case espresso
    case coffee
    case tea
    case energyDrink
    case custom

    var displayName: String {
        switch self {
        case .espresso: return "Espresso"
        case .coffee: return "Coffee"
        case .tea: return "Tea"
        case .energyDrink: return "Energy Drink"
        case .custom: return "Custom"
        }
    }

    var defaultMg: Double {
        switch self {
        case .espresso: return 63
        case .coffee: return 95
        case .tea: return 47
        case .energyDrink: return 80
        case .custom: return 0
        }
    }

    var emoji: String {
        switch self {
        case .espresso: return "☕️"
        case .coffee: return "☕️"
        case .tea: return "🍵"
        case .energyDrink: return "⚡️"
        case .custom: return "✏️"
        }
    }
}
