import Foundation
import Testing

@testable import Trio

@Suite("PatternDetector — Glucose Pattern Analysis")
struct PatternDetectorTests {

    // MARK: - Helpers

    private func date(dayOffset: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 5
        components.hour = hour
        components.minute = minute
        components.second = 0
        let calendar = Calendar(identifier: .gregorian)
        let anchor = calendar.date(from: components)!
        return anchor.addingTimeInterval(Double(dayOffset) * 86_400)
    }

    private func sample(dayOffset: Int, hour: Int, mgdL: Double) -> (date: Date, glucose: Double) {
        (date: date(dayOffset: dayOffset, hour: hour), glucose: mgdL)
    }

    private func meal(dayOffset: Int, hour: Int) -> (date: Date) {
        (date: date(dayOffset: dayOffset, hour: hour))
    }

    // MARK: - Empty / insufficient data

    @Test("Empty sample list → no patterns")
    func testEmptySamples() {
        let patterns = PatternDetector.detect(glucoseSamples: [], carbEntries: [])
        #expect(patterns.isEmpty)
    }

    @Test("Single day of data → no patterns (below minDayCount)")
    func testSingleDay_noPatterns() {
        let samples = (0 ..< 12).map { i in
            sample(dayOffset: 0, hour: i * 2, mgdL: 200)
        }
        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: [])
        #expect(patterns.isEmpty)
    }

    @Test("Two days of data → no patterns (below minDayCount = 3)")
    func testTwoDays_noPatterns() {
        let samples = [
            sample(dayOffset: 0, hour: 3, mgdL: 210),
            sample(dayOffset: 0, hour: 12, mgdL: 110),
            sample(dayOffset: 1, hour: 3, mgdL: 215),
            sample(dayOffset: 1, hour: 12, mgdL: 115)
        ]
        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: [])
        #expect(patterns.isEmpty)
    }

    // MARK: - Consistent highs

    @Test("Glucose ≥ 180 at 3 AM across 5 days → consistentHighs detected")
    func testConsistentHighsAt3AM_5days() {
        var samples: [(date: Date, glucose: Double)] = []
        for day in 0 ..< 5 {
            samples.append(sample(dayOffset: day, hour: 3, mgdL: 220))
            samples.append(sample(dayOffset: day, hour: 12, mgdL: 110))
        }

        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: [])

        let highPatterns = patterns.filter {
            if case .consistentHighs = $0.kind { return true }
            return false
        }
        #expect(!highPatterns.isEmpty, "Expected consistentHighs pattern for 3 AM readings ≥ 180.")
        #expect(highPatterns.first?.occurrenceCount == 5)
    }

    @Test("Single outlier high → not flagged as pattern (below minDayCount)")
    func testSingleOutlierHigh_notFlagged() {
        var samples: [(date: Date, glucose: Double)] = []
        for day in 0 ..< 5 {
            let mgdL: Double = (day == 2) ? 220 : 110
            samples.append(sample(dayOffset: day, hour: 3, mgdL: mgdL))
            samples.append(sample(dayOffset: day, hour: 12, mgdL: 110))
        }

        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: [])

        let highPatterns = patterns.filter {
            if case .consistentHighs = $0.kind { return true }
            return false
        }
        #expect(highPatterns.isEmpty, "Single outlier should not produce a recurring high pattern.")
    }

    @Test("Normal readings throughout → no consistentHighs pattern")
    func testNormalReadings_noHighPattern() {
        var samples: [(date: Date, glucose: Double)] = []
        for day in 0 ..< 5 {
            for hour in [3, 8, 12, 18] {
                samples.append(sample(dayOffset: day, hour: hour, mgdL: 110))
            }
        }

        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: [])

        let highPatterns = patterns.filter {
            if case .consistentHighs = $0.kind { return true }
            return false
        }
        #expect(highPatterns.isEmpty)
    }

    // MARK: - Consistent lows

    @Test("Glucose ≤ 70 at 3 AM across 5 days → consistentLows detected")
    func testConsistentLowsAt3AM_5days() {
        var samples: [(date: Date, glucose: Double)] = []
        for day in 0 ..< 5 {
            samples.append(sample(dayOffset: day, hour: 3, mgdL: 60))
            samples.append(sample(dayOffset: day, hour: 12, mgdL: 110))
        }

        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: [])

        let lowPatterns = patterns.filter {
            if case .consistentLows = $0.kind { return true }
            return false
        }
        #expect(!lowPatterns.isEmpty, "Expected consistentLows pattern for 3 AM readings ≤ 70.")
    }

    // MARK: - Post-meal spike

    @Test("Glucose spike ≥ 40 mg/dL within 60 min on 3+ distinct days → postMealSpike detected")
    func testPostMealSpike_3Days() {
        var samples: [(date: Date, glucose: Double)] = []
        var meals: [(date: Date)] = []

        for day in 0 ..< 4 {
            let mealTime = date(dayOffset: day, hour: 12)
            meals.append((date: mealTime))
            // Pre-meal reading
            samples.append((date: mealTime, glucose: 100))
            // Post-meal spike
            samples.append((date: mealTime.addingTimeInterval(2_400), glucose: 150)) // +40 mg/dL
        }
        // Add overnight readings so detect() has non-empty samples
        for day in 0 ..< 4 {
            samples.append(sample(dayOffset: day, hour: 3, mgdL: 110))
        }

        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: meals)

        let spikePatterns = patterns.filter {
            if case .postMealSpike = $0.kind { return true }
            return false
        }
        #expect(!spikePatterns.isEmpty, "Post-meal spikes on 4 distinct days should trigger detection.")
    }

    @Test("Meal spike on same day multiple times is not counted as multiple days")
    func testPostMealSpike_sameDayMeals_notMultipleDays() {
        // 3 meals on the same day, each spiking — should not satisfy minDayCount of 3 distinct days
        let day0 = date(dayOffset: 0, hour: 0)
        var samples: [(date: Date, glucose: Double)] = []
        var meals: [(date: Date)] = []

        for hour in [8, 12, 18] {
            let mealTime = day0.addingTimeInterval(Double(hour) * 3_600)
            meals.append((date: mealTime))
            samples.append((date: mealTime, glucose: 100))
            samples.append((date: mealTime.addingTimeInterval(2_400), glucose: 145))
        }

        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: meals)

        let spikePatterns = patterns.filter {
            if case .postMealSpike = $0.kind { return true }
            return false
        }
        #expect(spikePatterns.isEmpty, "3 meals on the same day should not satisfy the 3-distinct-day requirement.")
    }

    @Test("Post-meal rise below spikeRiseMgDl threshold → not flagged")
    func testPostMealSpike_smallRise_notFlagged() {
        var samples: [(date: Date, glucose: Double)] = []
        var meals: [(date: Date)] = []

        for day in 0 ..< 4 {
            let mealTime = date(dayOffset: day, hour: 12)
            meals.append((date: mealTime))
            samples.append((date: mealTime, glucose: 100))
            // Rise of only 20 mg/dL — below spikeRiseMgDl (40)
            samples.append((date: mealTime.addingTimeInterval(2_400), glucose: 120))
        }

        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: meals)

        let spikePatterns = patterns.filter {
            if case .postMealSpike = $0.kind { return true }
            return false
        }
        #expect(spikePatterns.isEmpty, "A rise below the threshold should not trigger a spike pattern.")
    }

    // MARK: - Multiple patterns coexist

    @Test("Consistent high and post-meal spike can both be detected simultaneously")
    func testMultiplePatterns_coexist() {
        var samples: [(date: Date, glucose: Double)] = []
        var meals: [(date: Date)] = []

        for day in 0 ..< 4 {
            // Consistent high at 3 AM
            samples.append(sample(dayOffset: day, hour: 3, mgdL: 210))
            // Post-meal spike at lunch
            let mealTime = date(dayOffset: day, hour: 12)
            meals.append((date: mealTime))
            samples.append((date: mealTime, glucose: 100))
            samples.append((date: mealTime.addingTimeInterval(2_400), glucose: 150))
        }

        let patterns = PatternDetector.detect(glucoseSamples: samples, carbEntries: meals)

        let hasHigh = patterns.contains { if case .consistentHighs = $0.kind { return true }; return false }
        let hasSpike = patterns.contains { if case .postMealSpike = $0.kind { return true }; return false }

        #expect(hasHigh, "Expected consistentHighs to be detected.")
        #expect(hasSpike, "Expected postMealSpike to be detected.")
    }

    // MARK: - Determinism

    @Test("detect is deterministic for identical input")
    func testDetect_deterministic() {
        var samples: [(date: Date, glucose: Double)] = []
        for day in 0 ..< 5 {
            samples.append(sample(dayOffset: day, hour: 3, mgdL: 210))
            samples.append(sample(dayOffset: day, hour: 12, mgdL: 110))
        }

        let first = PatternDetector.detect(glucoseSamples: samples, carbEntries: [])
        let second = PatternDetector.detect(glucoseSamples: samples, carbEntries: [])

        #expect(first.count == second.count)
        for (a, b) in zip(first, second) {
            #expect(a.summary == b.summary)
            #expect(a.occurrenceCount == b.occurrenceCount)
        }
    }
}
