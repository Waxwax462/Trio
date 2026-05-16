import Foundation

struct AppleHealthIREntry: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let source: AppleHealthIRSource
    /// Positive = increased resistance, negative = decreased resistance.
    /// Example: +12.0 means insulin is 12% less effective.
    let irDeltaPercent: Double
    /// Human-readable explanation, e.g. "Sleep: 5.5 h → +12.0% IR"
    let details: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: AppleHealthIRSource,
        irDeltaPercent: Double,
        details: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.irDeltaPercent = irDeltaPercent
        self.details = details
    }
}

enum AppleHealthIRSource: String, Codable, CaseIterable, Sendable {
    case sleep
    case steps
    case hrv
    case exercise

    var displayName: String {
        switch self {
        case .sleep: return "Sleep"
        case .steps: return "Activity"
        case .hrv: return "HRV / Stress"
        case .exercise: return "Exercise"
        }
    }

    var systemImage: String {
        switch self {
        case .sleep: return "moon.zzz.fill"
        case .steps: return "figure.walk"
        case .hrv: return "waveform.path.ecg"
        case .exercise: return "figure.run"
        }
    }
}
