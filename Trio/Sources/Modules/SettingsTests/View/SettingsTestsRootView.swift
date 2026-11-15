import SwiftUI
import Swinject

extension SettingsTests {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @State private var resultToApply: BasalBlockResult?

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    header: Text("Basal Rate Check"),
                    footer: Text(
                        "Looks at the last \(SettingsTests.Config.lookbackDays) days and uses only stretches without carbs, manual boluses, overrides, temp targets or low glucose. For each of them it compares the insulin that was actually delivered with how glucose moved. The result is an estimate. Discuss changes with your care team."
                    )
                ) {
                    Button(action: { state.analyze() }, label: {
                        HStack {
                            Text(state.hasAnalyzed ? "Analyze Again" : "Analyze")
                            Spacer()
                            if state.isWorking {
                                ProgressView()
                            }
                        }
                    })
                        .disabled(state.isWorking)
                }
                .listRowBackground(Color.chart)

                if state.hasAnalyzed {
                    if state.results.isEmpty {
                        Section {
                            Text("No basal schedule or no glucose data found.")
                                .foregroundStyle(Color.secondary)
                        }
                        .listRowBackground(Color.chart)
                    }

                    ForEach(state.results) { result in
                        resultSection(result)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Basal Rate Check")
            .navigationBarTitleDisplayMode(.automatic)
            .confirmationDialog(
                Text("Change Basal Rate"),
                isPresented: Binding(
                    get: { resultToApply != nil },
                    set: { if !$0 { resultToApply = nil } }
                ),
                titleVisibility: .visible,
                actions: {
                    if let result = resultToApply {
                        Button("Set \(state.timeRange(result)) to \(state.rate(result.proposedRate))") {
                            state.apply(result)
                            resultToApply = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { resultToApply = nil }
                },
                message: {
                    Text(
                        "The basal schedule is sent to the pump first. If the pump does not accept it, nothing is changed."
                    )
                }
            )
            .alert(
                Text("Basal Rate Check"),
                isPresented: $state.showError,
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(state.errorMessage ?? "") }
            )
        }

        private func resultSection(_ result: BasalBlockResult) -> some View {
            Section(header: Text(state.timeRange(result))) {
                row("Scheduled", state.rate(result.scheduledRate))
                row("Estimated Need", state.rate(result.medianNeed))
                row("Windows Used", "\(result.windows.count)")

                Text(state.verdictText(result))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)

                if result.proposedRate != nil {
                    Button(action: { resultToApply = result }, label: {
                        HStack {
                            Text("Suggested")
                            Spacer()
                            Text(state.rate(result.proposedRate)).bold()
                        }
                    })
                        .disabled(state.isWorking)
                }
            }
            .listRowBackground(Color.chart)
        }

        private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(Color.secondary)
            }
        }
    }
}
