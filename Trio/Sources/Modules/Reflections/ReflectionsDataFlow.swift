import Foundation

enum Reflections {
    enum Config {}

    enum Period: String, CaseIterable, Identifiable {
        case sevenDays = "7d"
        case thirtyDays = "30d"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sevenDays:
                return String(localized: "7 Days", comment: "Reflections period picker")
            case .thirtyDays:
                return String(localized: "30 Days", comment: "Reflections period picker")
            }
        }

        var days: Int {
            switch self {
            case .sevenDays: return 7
            case .thirtyDays: return 30
            }
        }
    }

    struct TIRResult {
        var inRange: Double
        var hypo: Double
        var hyper: Double
        var average: Double
    }
}

protocol ReflectionsProvider: Provider {}
