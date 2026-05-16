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
            footer: Text("Below the severe threshold → +20% IR. Between thresholds → linear increase. Above mild threshold → no effect.")
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
                    in: thresholds.sleepSevereDeprivationMax ... 10.0,
                    step: 0.5
                ) {
                    Text(String(format: "%.1f h", thresholds.sleepMildDeprivationMax))
                        .frame(minWidth: 50, alignment: .trailing)
                }
            }
        }
        .listRowBackground(Color.chart)
    }

    private var stepsSection: some View {
        Section(
            header: Text("Daily Steps"),
            footer: Text("Below low → no effect. Low → -3% IR. Medium → -5% IR. High → -8% IR.")
        ) {
            stepsRow("Low activity start", value: $thresholds.stepsLowMin, range: 500 ... (thresholds.stepsMediumMin - 500), step: 500)
            stepsRow("Medium activity start", value: $thresholds.stepsMediumMin, range: (thresholds.stepsLowMin + 500) ... (thresholds.stepsHighMin - 1_000), step: 500)
            stepsRow("High activity start", value: $thresholds.stepsHighMin, range: (thresholds.stepsMediumMin + 500) ... 20_000, step: 1_000)
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
            footer: Text("Very low → +15% IR. Low → +8% IR. Normal range → no effect. Above normal → -5% IR.")
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
        }
        .listRowBackground(Color.chart)
    }

    private var exerciseSection: some View {
        Section(
            header: Text("Exercise"),
            footer: Text("Below minimum → no effect. Moderate → -5% IR. Substantial → -10% IR. Heavy → -15% IR.")
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
        }
        .listRowBackground(Color.chart)
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
