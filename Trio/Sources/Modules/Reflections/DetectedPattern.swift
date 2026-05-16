import Foundation

// MARK: - DetectedPattern

/// A recurring glucose pattern identified by deterministic analysis of CoreData records.
/// All pattern detection is rule-based — no LLM involved.
struct DetectedPattern: Identifiable, Sendable {
    let id: UUID
    let kind: PatternKind
    /// Human-readable description of the pattern, e.g. "Consistent highs 02:00–04:00".
    let summary: String
    /// Number of occurrences that triggered this pattern within the analysis window.
    let occurrenceCount: Int
    /// Average glucose value (mg/dL) associated with this pattern.
    let averageGlucose: Double

    init(
        id: UUID = UUID(),
        kind: PatternKind,
        summary: String,
        occurrenceCount: Int,
        averageGlucose: Double
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.occurrenceCount = occurrenceCount
        self.averageGlucose = averageGlucose
    }
}

// MARK: - PatternKind

enum PatternKind: Sendable {
    /// Glucose consistently above the high threshold during a specific hour-of-day window.
    case consistentHighs(hourRange: ClosedRange<Int>)
    /// Glucose consistently below the low threshold during a specific hour-of-day window.
    case consistentLows(hourRange: ClosedRange<Int>)
    /// Glucose regularly spikes within an hour following recorded meal events.
    case postMealSpike

    var systemImage: String {
        switch self {
        case .consistentHighs: return "arrow.up.circle.fill"
        case .consistentLows: return "arrow.down.circle.fill"
        case .postMealSpike: return "fork.knife.circle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .consistentHighs: return "Recurring Highs"
        case .consistentLows: return "Recurring Lows"
        case .postMealSpike: return "Post-Meal Spike"
        }
    }
}
