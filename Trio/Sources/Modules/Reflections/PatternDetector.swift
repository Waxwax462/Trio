import CoreData
import Foundation

// MARK: - PatternDetector

/// Deterministic rule-based pattern detector. No LLM involved.
///
/// Scans glucose readings grouped by hour-of-day and looks for:
/// - Consistent highs (≥ highThreshold) recurring in the same 2-hour window on ≥ minDayCount days.
/// - Consistent lows (≤ lowThreshold) recurring in the same 2-hour window on ≥ minDayCount days.
/// - Post-meal spikes: glucose rises ≥ spikeRise mg/dL within 60 min after a carb entry.
enum PatternDetector {
    // MARK: - Thresholds

    static let highThreshold: Double = 180
    static let lowThreshold: Double = 70
    /// Minimum days a window must show highs/lows to count as a pattern.
    static let minDayCount: Int = 3
    /// Minimum glucose rise (mg/dL) within 60 min of a meal to flag a post-meal spike.
    static let spikeRiseMgDl: Double = 40

    // MARK: - Public API

    /// Runs all detectors against the supplied glucose samples and carb entries.
    /// - Parameters:
    ///   - glucoseSamples: Array of `(date: Date, glucose: Double)` tuples, sorted ascending.
    ///   - carbEntries: Array of `(date: Date)` tuples representing logged meals.
    /// - Returns: Array of `DetectedPattern`, deduplicated, sorted by occurrence count descending.
    static func detect(
        glucoseSamples: [(date: Date, glucose: Double)],
        carbEntries: [(date: Date)]
    ) -> [DetectedPattern] {
        guard !glucoseSamples.isEmpty else { return [] }

        var patterns: [DetectedPattern] = []
        patterns += detectConsistentHighs(samples: glucoseSamples)
        patterns += detectConsistentLows(samples: glucoseSamples)
        patterns += detectPostMealSpikes(samples: glucoseSamples, carbEntries: carbEntries)

        return patterns.sorted { $0.occurrenceCount > $1.occurrenceCount }
    }

    // MARK: - Consistent Highs

    private static func detectConsistentHighs(samples: [(date: Date, glucose: Double)]) -> [DetectedPattern] {
        detectWindowPattern(
            samples: samples,
            windowSize: 2,
            predicate: { $0 >= highThreshold },
            makeKind: { PatternKind.consistentHighs(hourRange: $0) },
            labelPrefix: "Consistent highs"
        )
    }

    // MARK: - Consistent Lows

    private static func detectConsistentLows(samples: [(date: Date, glucose: Double)]) -> [DetectedPattern] {
        detectWindowPattern(
            samples: samples,
            windowSize: 2,
            predicate: { $0 <= lowThreshold },
            makeKind: { PatternKind.consistentLows(hourRange: $0) },
            labelPrefix: "Recurring lows"
        )
    }

    // MARK: - Shared window-pattern engine

    /// Groups samples by calendar day and hour window, then counts distinct days where
    /// the average glucose in that window satisfies `predicate`.
    private static func detectWindowPattern(
        samples: [(date: Date, glucose: Double)],
        windowSize: Int,
        predicate: (Double) -> Bool,
        makeKind: (ClosedRange<Int>) -> PatternKind,
        labelPrefix: String
    ) -> [DetectedPattern] {
        let calendar = Calendar.current
        // Build: [windowStartHour: [dayString: [Double]]]
        var buckets: [Int: [String: [Double]]] = [:]

        for sample in samples {
            let components = calendar.dateComponents([.hour, .day, .month, .year], from: sample.date)
            guard let hour = components.hour,
                  let day = components.day,
                  let month = components.month,
                  let year = components.year
            else { continue }

            let windowStart = (hour / windowSize) * windowSize
            let dayKey = "\(year)-\(month)-\(day)"
            buckets[windowStart, default: [:]][dayKey, default: []].append(sample.glucose)
        }

        var patterns: [DetectedPattern] = []

        for (windowStart, dayMap) in buckets {
            // For each day, compute average glucose in this window
            var qualifyingDayAverages: [Double] = []
            for (_, readings) in dayMap {
                let avg = readings.reduce(0, +) / Double(readings.count)
                if predicate(avg) {
                    qualifyingDayAverages.append(avg)
                }
            }

            guard qualifyingDayAverages.count >= minDayCount else { continue }

            let windowEnd = windowStart + windowSize - 1
            let range = windowStart ... windowEnd
            let overallAvg = qualifyingDayAverages.reduce(0, +) / Double(qualifyingDayAverages.count)

            let summary = String(
                format: "%@ %02d:00–%02d:59 (%d days, avg %.0f mg/dL)",
                labelPrefix,
                windowStart,
                windowEnd,
                qualifyingDayAverages.count,
                overallAvg
            )

            patterns.append(DetectedPattern(
                kind: makeKind(range),
                summary: summary,
                occurrenceCount: qualifyingDayAverages.count,
                averageGlucose: overallAvg
            ))
        }

        return patterns
    }

    // MARK: - Post-Meal Spike

    private static func detectPostMealSpikes(
        samples: [(date: Date, glucose: Double)],
        carbEntries: [(date: Date)]
    ) -> [DetectedPattern] {
        guard !carbEntries.isEmpty else { return [] }

        let calendar = Calendar.current
        var spikeDays: Set<String> = []
        var spikeMagnitudes: [Double] = []

        for meal in carbEntries {
            // Find glucose reading closest to (but at or after) meal time.
            guard let baseReading = samples.first(where: { $0.date >= meal.date }) else { continue }
            let windowEnd = meal.date.addingTimeInterval(3_600) // 60 min

            let windowSamples = samples.filter { $0.date > meal.date && $0.date <= windowEnd }
            guard !windowSamples.isEmpty else { continue }

            let peakGlucose = windowSamples.map(\.glucose).max() ?? baseReading.glucose
            let rise = peakGlucose - baseReading.glucose

            if rise >= spikeRiseMgDl {
                let c = calendar.dateComponents([.year, .month, .day], from: meal.date)
                if let y = c.year, let m = c.month, let d = c.day {
                    spikeDays.insert("\(y)-\(m)-\(d)")
                }
                spikeMagnitudes.append(rise)
            }
        }

        guard spikeDays.count >= minDayCount else { return [] }

        let avgRise = spikeMagnitudes.reduce(0, +) / Double(spikeMagnitudes.count)
        let summary = String(
            format: "Post-meal spike ≥%.0f mg/dL on %d days (avg rise %.0f mg/dL)",
            spikeRiseMgDl,
            spikeDays.count,
            avgRise
        )

        return [DetectedPattern(
            kind: .postMealSpike,
            summary: summary,
            occurrenceCount: spikeDays.count,
            averageGlucose: avgRise
        )]
    }
}
