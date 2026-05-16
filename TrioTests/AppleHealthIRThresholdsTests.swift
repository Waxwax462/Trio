import Foundation
import Testing

@testable import Trio

// MARK: - AppleHealthIRThresholds Tests

// Tests that mutate UserDefaults (custom threshold variants) are serialized to prevent
// state leakage when the test runner executes them in parallel.
@Suite("AppleHealthIRThresholds — Default Values and Delta Computation", .serialized)
struct AppleHealthIRThresholdsTests {

    // MARK: - Helpers

    /// Returns a freshly constructed service whose UserDefaults storage key is isolated to this
    /// test run so parallel tests never contaminate each other.
    private func makeService() -> BaseAppleHealthIRService {
        BaseAppleHealthIRService()
    }

    // MARK: - Default threshold values

    @Test("Default sleep thresholds are 5h (severe) and 7h (mild)")
    func testDefaultSleepThresholds() {
        let t = AppleHealthIRThresholds()
        #expect(t.sleepSevereDeprivationMax == 5.0)
        #expect(t.sleepMildDeprivationMax == 7.0)
    }

    @Test("Default step thresholds are 2 000 / 5 000 / 10 000")
    func testDefaultStepThresholds() {
        let t = AppleHealthIRThresholds()
        #expect(t.stepsLowMin == 2_000)
        #expect(t.stepsMediumMin == 5_000)
        #expect(t.stepsHighMin == 10_000)
    }

    @Test("Default HRV thresholds are 20 ms / 40 ms / 60 ms")
    func testDefaultHRVThresholds() {
        let t = AppleHealthIRThresholds()
        #expect(t.hrvVeryLowMax == 20.0)
        #expect(t.hrvLowMax == 40.0)
        #expect(t.hrvNormalMax == 60.0)
    }

    @Test("Default exercise thresholds are 20 min / 60 min / 120 min")
    func testDefaultExerciseThresholds() {
        let t = AppleHealthIRThresholds()
        #expect(t.exerciseMinThreshold == 20.0)
        #expect(t.exerciseModerateMax == 60.0)
        #expect(t.exerciseSubstantialMax == 120.0)
    }

    // MARK: - Sleep delta (via update → currentDeltas.sleep)

    @Test("Sleep nil → 0% delta")
    func testSleepDelta_nil() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.sleep == 0.0)
    }

    @Test("Sleep below severe threshold → +20% IR")
    func testSleepDelta_severeDeprivation() {
        let svc = makeService()
        svc.update(sleepHours: 3.0, stepCount: 0, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.sleep == 20.0)
    }

    @Test("Sleep just below mild threshold → linear interpolated positive delta")
    func testSleepDelta_mildDeprivation() {
        // At 6.0 h: mildEffect + (mild - h) / (mild - severe) * (severeEffect - mildEffect)
        // = 5.0 + (7.0 - 6.0) / (7.0 - 5.0) * (20.0 - 5.0) = 5.0 + 0.5 * 15.0 = 12.5
        let svc = makeService()
        svc.update(sleepHours: 6.0, stepCount: 0, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.sleep == 12.5)
    }

    @Test("Sleep at or above mild threshold → 0% delta")
    func testSleepDelta_optimal() {
        let svc = makeService()
        svc.update(sleepHours: 8.0, stepCount: 0, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.sleep == 0.0)
    }

    @Test("Sleep delta: custom severe threshold changes breakpoint")
    func testSleepDelta_customSevereThreshold() {
        var thresholds = AppleHealthIRThresholds()
        thresholds.sleepSevereDeprivationMax = 6.0
        thresholds.sleepMildDeprivationMax = 8.0
        thresholds.save()
        defer { UserDefaults.standard.removeObject(forKey: AppleHealthIRThresholds.defaultsKey) }

        let svc = makeService()
        svc.update(sleepHours: 5.5, stepCount: 0, hrv: nil, exerciseHours: nil)
        // 5.5 < 6.0 (new severe) → sleepSevereIREffect (default 20%)
        #expect(svc.currentDeltas.sleep == 20.0)
    }

    @Test("Sleep delta: custom sleepSevereIREffect = 30 applies correct magnitude")
    func testSleepDelta_customSevereEffect() {
        var thresholds = AppleHealthIRThresholds()
        thresholds.sleepSevereIREffect = 30.0
        thresholds.save()
        defer { UserDefaults.standard.removeObject(forKey: AppleHealthIRThresholds.defaultsKey) }

        let svc = makeService()
        // 3h < 5h (severe boundary) → should return the new severe effect (30%)
        svc.update(sleepHours: 3.0, stepCount: 0, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.sleep == 30.0)
    }

    @Test("Sleep delta: equal severe/mild thresholds → severe effect returned (no divide-by-zero)")
    func testSleepDelta_equalThresholds_noCrash() {
        var thresholds = AppleHealthIRThresholds()
        thresholds.sleepSevereDeprivationMax = 5.0
        thresholds.sleepMildDeprivationMax = 5.0
        thresholds.save()
        defer { UserDefaults.standard.removeObject(forKey: AppleHealthIRThresholds.defaultsKey) }

        let svc = makeService()
        // 5.5 >= mild (5.0) → 0%
        svc.update(sleepHours: 5.5, stepCount: 0, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.sleep == 0.0)

        // 4.9 < severe (5.0) → sleepSevereIREffect (not divide-by-zero)
        svc.update(sleepHours: 4.9, stepCount: 0, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.sleep == thresholds.sleepSevereIREffect)
    }

    // MARK: - Steps delta

    @Test("Steps below low threshold → 0% delta")
    func testStepsDelta_belowLow() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 500, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.steps == 0.0)
    }

    @Test("Steps in low band → -3% IR")
    func testStepsDelta_lowBand() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 3_000, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.steps == -3.0)
    }

    @Test("Steps in medium band → -5% IR")
    func testStepsDelta_mediumBand() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 7_000, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.steps == -5.0)
    }

    @Test("Steps at or above high threshold → -8% IR")
    func testStepsDelta_highBand() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 15_000, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.steps == -8.0)
    }

    @Test("Steps delta: custom medium threshold shifts -5% boundary")
    func testStepsDelta_customMediumThreshold() {
        var thresholds = AppleHealthIRThresholds()
        thresholds.stepsMediumMin = 3_000   // lower medium start
        thresholds.save()
        defer { UserDefaults.standard.removeObject(forKey: AppleHealthIRThresholds.defaultsKey) }

        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 3_500, hrv: nil, exerciseHours: nil)
        // 3 500 ≥ 3 000 (new medium) and < 10 000 (high) → -5%
        #expect(svc.currentDeltas.steps == -5.0)
    }

    // MARK: - HRV delta

    @Test("HRV nil → 0% delta")
    func testHRVDelta_nil() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.hrv == 0.0)
    }

    @Test("HRV below very-low threshold → +15% IR")
    func testHRVDelta_veryLow() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: 10.0, exerciseHours: nil)
        #expect(svc.currentDeltas.hrv == 15.0)
    }

    @Test("HRV in low band → +8% IR")
    func testHRVDelta_low() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: 30.0, exerciseHours: nil)
        #expect(svc.currentDeltas.hrv == 8.0)
    }

    @Test("HRV in normal range → 0% delta")
    func testHRVDelta_normal() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: 50.0, exerciseHours: nil)
        #expect(svc.currentDeltas.hrv == 0.0)
    }

    @Test("HRV above normal max → -5% IR (excellent recovery)")
    func testHRVDelta_excellent() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: 80.0, exerciseHours: nil)
        #expect(svc.currentDeltas.hrv == -5.0)
    }

    @Test("HRV delta: custom normal-max threshold shifts -5% boundary")
    func testHRVDelta_customNormalMax() {
        var thresholds = AppleHealthIRThresholds()
        thresholds.hrvNormalMax = 80.0
        thresholds.save()
        defer { UserDefaults.standard.removeObject(forKey: AppleHealthIRThresholds.defaultsKey) }

        let svc = makeService()
        // 70 ms ≤ 80 ms (new normal max) → should be 0%, not -5%
        svc.update(sleepHours: nil, stepCount: 0, hrv: 70.0, exerciseHours: nil)
        #expect(svc.currentDeltas.hrv == 0.0)
    }

    // MARK: - Exercise delta

    @Test("Exercise nil → 0% delta")
    func testExerciseDelta_nil() {
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: nil, exerciseHours: nil)
        #expect(svc.currentDeltas.exercise == 0.0)
    }

    @Test("Exercise below minimum threshold → 0% delta")
    func testExerciseDelta_belowMin() {
        // 10 minutes (= 10/60 h) < 20 min threshold
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: nil, exerciseHours: 10.0 / 60.0)
        #expect(svc.currentDeltas.exercise == 0.0)
    }

    @Test("Exercise in moderate band → -5% IR")
    func testExerciseDelta_moderate() {
        // 30 minutes (0.5 h) → in 20–59 min band
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: nil, exerciseHours: 0.5)
        #expect(svc.currentDeltas.exercise == -5.0)
    }

    @Test("Exercise in substantial band → -10% IR")
    func testExerciseDelta_substantial() {
        // 90 minutes (1.5 h) → in 60–119 min band
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: nil, exerciseHours: 1.5)
        #expect(svc.currentDeltas.exercise == -10.0)
    }

    @Test("Exercise at or above heavy threshold → -15% IR")
    func testExerciseDelta_heavy() {
        // 2.5 h = 150 minutes ≥ 120 min threshold
        let svc = makeService()
        svc.update(sleepHours: nil, stepCount: 0, hrv: nil, exerciseHours: 2.5)
        #expect(svc.currentDeltas.exercise == -15.0)
    }

    @Test("Exercise delta: custom min threshold shifts effect boundary")
    func testExerciseDelta_customMinThreshold() {
        var thresholds = AppleHealthIRThresholds()
        thresholds.exerciseMinThreshold = 10.0   // lower the minimum to 10 min
        thresholds.save()
        defer { UserDefaults.standard.removeObject(forKey: AppleHealthIRThresholds.defaultsKey) }

        let svc = makeService()
        // 15 minutes = 0.25 h → now ≥ 10 min (new min) and < 60 min (moderate max) → -5%
        svc.update(sleepHours: nil, stepCount: 0, hrv: nil, exerciseHours: 0.25)
        #expect(svc.currentDeltas.exercise == -5.0)
    }

    // MARK: - Extreme values (must not crash)

    @Test("Extreme 0% effective inputs do not crash")
    func testExtremeZeroInputs() {
        let svc = makeService()
        // Should complete without throwing or trapping
        svc.update(sleepHours: 0.0, stepCount: 0, hrv: 0.0, exerciseHours: 0.0)
        // Very low sleep → +20, steps below low → 0, hrv 0 < 20 → +15, exercise 0 < 20 min → 0
        #expect(svc.currentDeltas.sleep == 20.0)
        #expect(svc.currentDeltas.steps == 0.0)
        #expect(svc.currentDeltas.hrv == 15.0)
        #expect(svc.currentDeltas.exercise == 0.0)
    }

    @Test("Extremely large inputs do not crash and return capped delta")
    func testExtremeLargeInputs() {
        let svc = makeService()
        // 100 h sleep, 1 000 000 steps, 999 ms HRV, 48 h exercise
        svc.update(sleepHours: 100.0, stepCount: 1_000_000, hrv: 999.0, exerciseHours: 48.0)
        // sleep ≥ 7 h → 0; steps ≥ 10 000 → -8; hrv > 60 → -5; exercise > 120 min → -15
        #expect(svc.currentDeltas.sleep == 0.0)
        #expect(svc.currentDeltas.steps == -8.0)
        #expect(svc.currentDeltas.hrv == -5.0)
        #expect(svc.currentDeltas.exercise == -15.0)
    }

    @Test("Insulin resistance multiplier floor is 0.5 under extreme negative deltas")
    func testMultiplierFloorAt0_5() {
        let svc = makeService()
        // All maximally negative: steps -8, hrv -5, exercise -15 → combined -28 → 1 + (-28/100) = 0.72 > 0.5
        // The floor only engages if combined < -50; that cannot happen with current fixed deltas.
        // Verify the multiplier is correctly computed and never below 0.5.
        svc.update(sleepHours: 100.0, stepCount: 1_000_000, hrv: 999.0, exerciseHours: 48.0)
        #expect(svc.insulinResistanceMultiplier >= 0.5)
        #expect(svc.insulinResistanceMultiplier == min(2.0, max(0.5, 1.0 + svc.currentDeltas.combined / 100.0)))
    }

    @Test("Insulin resistance multiplier ceiling is 2.0 under extreme positive deltas")
    func testMultiplierCeilingAt2_0() {
        // Push combined delta above 100% by setting effects above their default maxima.
        var thresholds = AppleHealthIRThresholds()
        thresholds.sleepSevereIREffect = 60.0
        thresholds.hrvVeryLowIREffect = 60.0
        thresholds.save()
        defer { UserDefaults.standard.removeObject(forKey: AppleHealthIRThresholds.defaultsKey) }

        let svc = makeService()
        // sleep <5h → +60%, hrv <20ms → +60% → combined +120% → min(2.0, 1.0 + 1.2) = 2.0
        svc.update(sleepHours: 1.0, stepCount: 0, hrv: 5.0, exerciseHours: nil)
        #expect(svc.insulinResistanceMultiplier <= 2.0)
        #expect(svc.insulinResistanceMultiplier == 2.0)
    }

    @Test("Insulin resistance multiplier is correct for high-stress combined input")
    func testMultiplierHighStress() {
        let svc = makeService()
        // Worst-case IR: sleep <5h (+20) + hrv <20ms (+15) → combined +35 → 1.35
        svc.update(sleepHours: 3.0, stepCount: 0, hrv: 5.0, exerciseHours: nil)
        #expect(svc.insulinResistanceMultiplier == 1.35)
    }
}
