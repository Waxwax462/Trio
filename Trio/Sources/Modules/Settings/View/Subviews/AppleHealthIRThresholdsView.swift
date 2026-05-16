import SwiftUI
import Swinject

struct AppleHealthIRThresholdsView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: Settings.StateModel

    @State private var thresholds = AppleHealthIRThresholds.current
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            sleepSection
            stepsSection
            hrvSection
            exerciseSection
            resetSection
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Biometric Thresholds")
        .navigationBarTitleDisplayMode(.automatic)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { thresholds.save() }
            }
        }
    }

    private var sleepSection: some View {
        Section(
            header: Text("Sleep"),
            footer: Text("Below the severe threshold → severe IR effect. Between thresholds → linear increase. Above mild threshold → no effect.")
        ) {
            LabeledContent("Severe deprivation below (h)") {
                Stepper(
                    value: $thresholds.sleepSevereDeprivationMax,
                    in: 2.0 ... 6.0,
                    step: 0.5
                ) {
                    Text(String(format: "%.1f h", thresholds.sleepSevereDeprivationMax))
                        .frame(minWidth: 50, alignment: .trailing)
                }
            }
            LabeledContent("Mild deprivation below (h)") {
                Stepper(
                    value: $thresholds.sleepMildDeprivationMax,
                    in: (thresholds.sleepSevereDeprivationMax + 0.5) ... 10.0,
                    step: 0.5
                ) {
                    Text(String(format: "%.1f h", thresholds.sleepMildDeprivationMax))
                        .frame(minWidth: 50, alignment: .trailing)
                }
            }
            irEffectRow("Severe IR effect (%)", value: $thresholds.sleepSevereIREffect, range: 5.0 ... 30.0, step: 1.0)
            irEffectRow("Mild IR effect (%)", value: $thresholds.sleepMildIREffect, range: 0.0 ... thresholds.sleepSevereIREffect, step: 1.0)
        }
        .listRowBackground(Color.chart)
    }

    private var stepsSection: some View {
        Section(
            header: Text("Daily Steps"),
            footer: Text("Below low → no effect. Thresholds define band start. IR effects are negative (improved sensitivity).")
        ) {
            stepsRow("Low activity start", value: $thresholds.stepsLowMin, range: 500 ... (thresholds.stepsMediumMin - 500), step: 500)
            stepsRow("Medium activity start", value: $thresholds.stepsMediumMin, range: (thresholds.stepsLowMin + 500) ... (thresholds.stepsHighMin - 1_000), step: 500)
            stepsRow("High activity start", value: $thresholds.stepsHighMin, range: (thresholds.stepsMediumMin + 500) ... 20_000, step: 1_000)
            irEffectRow("Low activity IR effect (%)", value: $thresholds.stepsLowIREffect, range: -20.0 ... 0.0, step: 1.0)
            irEffectRow("Medium activity IR effect (%)", value: $thresholds.stepsMediumIREffect, range: -20.0 ... 0.0, step: 1.0)
            irEffectRow("High activity IR effect (%)", value: $thresholds.stepsHighIREffect, range: -20.0 ... 0.0, step: 1.0)
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder private func stepsRow(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        LabeledContent(label) {
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue) steps")
                    .frame(minWidth: 90, alignment: .trailing)
            }
        }
    }

    private var hrvSection: some View {
        Section(
            header: Text("Heart Rate Variability (HRV)"),
            footer: Text("Very low / low HRV → positive IR effect (more resistance). Normal range → no effect. Above normal → negative IR effect (less resistance).")
        ) {
            LabeledContent("Very low HRV below (ms)") {
                Stepper(value: $thresholds.hrvVeryLowMax, in: 5.0 ... 30.0, step: 5.0) {
                    Text(String(format: "%.0f ms", thresholds.hrvVeryLowMax))
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
            LabeledContent("Low HRV below (ms)") {
                Stepper(value: $thresholds.hrvLowMax, in: thresholds.hrvVeryLowMax ... 70.0, step: 5.0) {
                    Text(String(format: "%.0f ms", thresholds.hrvLowMax))
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
            LabeledContent("Normal HRV up to (ms)") {
                Stepper(value: $thresholds.hrvNormalMax, in: thresholds.hrvLowMax ... 120.0, step: 5.0) {
                    Text(String(format: "%.0f ms", thresholds.hrvNormalMax))
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
            irEffectRow("Very low HRV IR effect (%)", value: $thresholds.hrvVeryLowIREffect, range: 0.0 ... 30.0, step: 1.0)
            irEffectRow("Low HRV IR effect (%)", value: $thresholds.hrvLowIREffect, range: 0.0 ... thresholds.hrvVeryLowIREffect, step: 1.0)
            irEffectRow("High HRV IR effect (%)", value: $thresholds.hrvHighIREffect, range: -20.0 ... 0.0, step: 1.0)
        }
        .listRowBackground(Color.chart)
    }

    private var exerciseSection: some View {
        Section(
            header: Text("Exercise"),
            footer: Text("Below minimum → no effect. IR effects are negative (improved sensitivity). Values increase in magnitude from moderate to heavy.")
        ) {
            LabeledContent("Minimum for effect (min)") {
                Stepper(value: $thresholds.exerciseMinThreshold, in: 5.0 ... 45.0, step: 5.0) {
                    Text(String(format: "%.0f min", thresholds.exerciseMinThreshold))
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
            LabeledContent("Moderate ends at (min)") {
                Stepper(value: $thresholds.exerciseModerateMax, in: thresholds.exerciseMinThreshold ... 90.0, step: 5.0) {
                    Text(String(format: "%.0f min", thresholds.exerciseModerateMax))
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
            LabeledContent("Heavy threshold (min)") {
                Stepper(value: $thresholds.exerciseSubstantialMax, in: thresholds.exerciseModerateMax ... 240.0, step: 15.0) {
                    Text(String(format: "%.0f min", thresholds.exerciseSubstantialMax))
                        .frame(minWidth: 60, alignment: .trailing)
                }
            }
            irEffectRow("Moderate IR effect (%)", value: $thresholds.exerciseModerateIREffect, range: -30.0 ... 0.0, step: 1.0)
            irEffectRow("Substantial IR effect (%)", value: $thresholds.exerciseSubstantialIREffect, range: -30.0 ... thresholds.exerciseModerateIREffect, step: 1.0)
            irEffectRow("Heavy IR effect (%)", value: $thresholds.exerciseHeavyIREffect, range: -30.0 ... thresholds.exerciseSubstantialIREffect, step: 1.0)
        }
        .listRowBackground(Color.chart)
    }

    /// Reusable stepper row for IR effect percentage fields.
    @ViewBuilder private func irEffectRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        LabeledContent(label) {
            Stepper(value: value, in: range, step: step) {
                Text(String(format: "%+.0f%%", value.wrappedValue))
                    .frame(minWidth: 55, alignment: .trailing)
                    .foregroundStyle(value.wrappedValue > 0 ? .red : (value.wrappedValue < 0 ? .green : .secondary))
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to Defaults", role: .destructive) {
                thresholds = AppleHealthIRThresholds()
                thresholds.save()
            }
        }
        .listRowBackground(Color.chart)
    }
}
