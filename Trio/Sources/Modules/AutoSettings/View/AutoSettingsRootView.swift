import SwiftUI
import Swinject

extension AutoSettings {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @State private var changeToUndo: AutoSettingsChange?
        @State private var isConfirmingBaseline = false
        @State private var isConfirmingAutomatic = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                modeSection
                if state.settings.mode != .off {
                    scopeSection
                    statusSection
                    proposalsSection
                }
                historySection
                if state.settings.mode != .off {
                    baselineSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Self-Adjusting Settings")
            .navigationBarTitleDisplayMode(.automatic)
            .onChange(of: state.settings) { _, _ in
                state.saveSettings()
            }
            .alert(isPresented: $state.showError) {
                Alert(
                    title: Text("Not Changed"),
                    message: Text(state.errorMessage ?? ""),
                    dismissButton: .default(Text("OK"))
                )
            }
            .confirmationDialog(
                Text("Undo Change"),
                isPresented: Binding(
                    get: { changeToUndo != nil },
                    set: { if !$0 { changeToUndo = nil } }
                ),
                titleVisibility: .visible,
                actions: {
                    if let change = changeToUndo {
                        Button("Set Back to \(state.value(change.oldValue, kind: change.kind))") {
                            state.undo(change)
                            changeToUndo = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { changeToUndo = nil }
                },
                message: {
                    Text("The value is set back and then left alone for \(Int(state.limits.undoBlockDays)) days.")
                }
            )
            .confirmationDialog(
                Text("Use Current Settings as Baseline"),
                isPresented: $isConfirmingBaseline,
                titleVisibility: .visible,
                actions: {
                    Button("Confirm Baseline") { state.confirmBaseline() }
                    Button("Cancel", role: .cancel) {}
                },
                message: {
                    Text(
                        "Changes stay within \(Int(state.limits.band * 100)) % of the baseline. Confirm only if the current settings work well for you: from now on the range is measured from them."
                    )
                }
            )
            .confirmationDialog(
                Text("Change Settings Automatically"),
                isPresented: $isConfirmingAutomatic,
                titleVisibility: .visible,
                actions: {
                    Button("Switch On") { state.settings.mode = .automatic }
                    Button("Cancel", role: .cancel) {}
                },
                message: {
                    Text(
                        "Trio will change basal rates, insulin sensitivity and carb ratio without asking, in both directions, within the limits shown on this screen. These are estimates from your data, not medical advice. Check the log regularly and discuss the changes with your care team."
                    )
                }
            )
        }

        // MARK: - Mode

        private var modeSection: some View {
            Section(
                header: Text("Mode"),
                footer: Text(
                    "Once a day Trio estimates from the last \(BaseAutoSettingsManager.lookbackDays) days what your basal rates, insulin sensitivity and carb ratio should be. In shadow mode it only shows what it would change. In automatic mode it changes the settings itself, in small steps."
                )
            ) {
                Picker(
                    "Mode",
                    selection: Binding(
                        get: { state.settings.mode },
                        set: { mode in
                            if mode == .automatic, state.settings.mode != .automatic {
                                isConfirmingAutomatic = true
                            } else {
                                state.settings.mode = mode
                            }
                        }
                    )
                ) {
                    Text("Off").tag(AutoSettingsMode.off)
                    Text("Shadow").tag(AutoSettingsMode.shadow)
                    Text("Automatic").tag(AutoSettingsMode.automatic)
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.chart)
        }

        private var scopeSection: some View {
            Section(
                header: Text("What Is Learned"),
                footer: Text(
                    "Sport profiles and the hours after them do not count for the base settings. The recovery phase of each sport profile learns its own percentage instead. With Dynamic ISF switched on, insulin sensitivity is left to Dynamic ISF."
                )
            ) {
                Toggle("Basal Rates", isOn: $state.settings.adaptBasal)
                Toggle("Insulin Sensitivity", isOn: $state.settings.adaptSensitivity)
                Toggle("Carb Ratio", isOn: $state.settings.adaptCarbRatio)
                Toggle("Sport Recovery Phases", isOn: $state.settings.adaptSportRecovery)
                Stepper(value: $state.settings.sportAfterEffectHours, in: 0 ... 24, step: 1) {
                    Text("After Sport: \(state.settings.sportAfterEffectHours) h Excluded")
                }
                Toggle("Notify on Changes", isOn: $state.settings.notify)
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - Status

        private var statusSection: some View {
            Section(
                header: Text("Status"),
                footer: Text(
                    "Limits: at most \(percent(state.limits.lessInsulinStep)) per step towards less insulin and \(percent(state.limits.moreInsulinStep)) towards more, one step every \(Int(state.limits.daysBetweenSteps)) days per value, one kind of setting at a time, never more than \(Int(state.limits.band * 100)) % away from the baseline. A basal rate moves by one pump increment where the pump cannot do a smaller step. After a low, steps towards more insulin pause for \(Int(state.limits.freezeDays)) days and the latest one is taken back."
                )
            ) {
                HStack {
                    Text("Last Run")
                    Spacer()
                    if let lastRun = state.lastRun {
                        Text(lastRun, format: .dateTime.day().month().hour().minute()).foregroundStyle(Color.secondary)
                    } else {
                        Text("Never").foregroundStyle(Color.secondary)
                    }
                }

                if let frozenUntil = state.frozenUntil {
                    HStack {
                        Text("More Insulin Paused Until")
                        Spacer()
                        Text(frozenUntil, format: .dateTime.day().month().hour().minute()).foregroundStyle(Color.orange)
                    }
                }
                if let sportFrozenUntil = state.sportFrozenUntil {
                    HStack {
                        Text("Sport Recovery Paused Until")
                        Spacer()
                        Text(sportFrozenUntil, format: .dateTime.day().month().hour().minute()).foregroundStyle(Color.orange)
                    }
                }

                Button(action: { state.runNow() }, label: {
                    HStack {
                        Text("Run Now")
                        Spacer()
                        if state.isWorking {
                            ProgressView()
                        }
                    }
                })
                    .disabled(state.isWorking)
            }
            .listRowBackground(Color.chart)
        }

        private func percent(_ fraction: Double) -> String {
            String(format: "%g %%", fraction * 100)
        }

        // MARK: - Proposals

        @ViewBuilder private var proposalsSection: some View {
            if !state.proposals.isEmpty {
                Section(header: Text("Estimates")) {
                    ForEach(state.proposals) { proposal in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(
                                    "\(proposal.kind.localizedName) \(state.place(kind: proposal.kind, scopeName: proposal.scopeName, blockStartMinute: proposal.blockStartMinute))"
                                )
                                Spacer()
                                Text(state.value(proposal.current, kind: proposal.kind))
                            }
                            HStack {
                                Text(state.verdictText(proposal))
                                    .foregroundStyle(verdictColor(proposal.verdict))
                                Spacer()
                                if let proposed = proposal.proposed {
                                    Text("→ \(state.value(proposed, kind: proposal.kind))")
                                        .foregroundStyle(verdictColor(proposal.verdict))
                                }
                            }
                            .font(.footnote)
                            if proposal.estimate != nil {
                                Text(
                                    "Estimate \(state.value(proposal.estimate, kind: proposal.kind)) from \(proposal.sampleCount) observations on \(proposal.dayCount) days"
                                )
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
                .listRowBackground(Color.chart)
            }
        }

        private func verdictColor(_ verdict: AutoSettingsVerdict) -> Color {
            switch verdict {
            case .change,
                 .waiting:
                return Color.accentColor
            case .atLimit,
                 .frozen:
                return Color.orange
            default:
                return Color.secondary
            }
        }

        // MARK: - History

        @ViewBuilder private var historySection: some View {
            if !state.history.isEmpty {
                Section(header: Text("Changes")) {
                    ForEach(state.history) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(
                                    "\(change.kind.localizedName) \(state.place(kind: change.kind, scopeName: change.scopeName, blockStartMinute: change.blockStartMinute))"
                                )
                                Spacer()
                                Text(change.date, format: .dateTime.day().month().hour().minute())
                                    .foregroundStyle(Color.secondary)
                            }
                            HStack {
                                Text(
                                    "\(state.value(change.oldValue, kind: change.kind)) → \(state.value(change.newValue, kind: change.kind))"
                                )
                                Spacer()
                                if state.canUndo(change) {
                                    Button("Undo") { changeToUndo = change }
                                        .buttonStyle(.borderless)
                                        .disabled(state.isWorking)
                                }
                            }
                            .font(.footnote)
                            Text(state.reasonText(change))
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
                .listRowBackground(Color.chart)
            }
        }

        // MARK: - Baseline

        private var baselineSection: some View {
            Section(
                footer: Text(
                    "The baseline is what your settings were when the learner first saw them, or after you last edited them by hand. An edit in one of the settings editors always wins: it becomes the new baseline and the learner waits before touching that value again."
                )
            ) {
                Button("Use Current Settings as Baseline") { isConfirmingBaseline = true }
            }
            .listRowBackground(Color.chart)
        }
    }
}
