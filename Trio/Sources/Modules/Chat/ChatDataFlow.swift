import Foundation

enum Chat {
    enum Config {}
}

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable {
    var id: UUID
    var role: ChatRole
    var content: String
    var timestamp: Date
}

struct ChatContext {
    var currentGlucose: Double?
    var glucoseUnit: String
    var iob: Double?
    var cob: Double?
    var heartRate: Double?
    var currentCaffeineMg: Double
    var isSickDayModeActive: Bool

    static var empty: ChatContext {
        ChatContext(
            currentGlucose: nil,
            glucoseUnit: "mg/dL",
            iob: nil,
            cob: nil,
            heartRate: nil,
            currentCaffeineMg: 0,
            isSickDayModeActive: false
        )
    }
}

protocol ChatProvider: Provider {}
