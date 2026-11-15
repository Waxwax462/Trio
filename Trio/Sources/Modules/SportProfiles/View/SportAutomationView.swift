import SwiftUI

extension SportProfiles {
    /// Settings for starting sport profiles from a Garmin activity.
    struct SportAutomationView: View {
        @ObservedObject var state: StateModel

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            Form {
                Section(
                    header: Text("Garmin"),
                    footer: Text(
                        "The Trio data field on your Garmin device asks the phone for data every five minutes while an activity screen is open. Trio takes the first request as the start of an activity, so the profile starts up to five minutes after you open the activity. Trio cannot see the moment you press start or stop."
                    )
                ) {
                    Toggle("Start When Activity Begins", isOn: $state.automation.garminEnabled)

                    Picker("Sport Profile", selection: $state.automation.profileID) {
                        Text("None").tag(String?.none)
                        ForEach(state.profiles) { profile in
                            Text(profile.name).tag(String?.some(profile.id))
                        }
                    }

                    Picker("Start With", selection: $state.automation.startPhase) {
                        ForEach(SportPhaseKind.allCases, id: \.self) { kind in
                            Text(kind.localizedName).tag(kind)
                        }
                    }
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("During the Activity"),
                    footer: Text(
                        "With this on, the sport phase does not run out while the data field is still active. It is extended in steps of 15 minutes."
                    )
                ) {
                    Toggle("Keep Sport Phase Running", isOn: $state.automation.extendWhileActive)
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("When the Activity Ends"),
                    footer: Text(
                        "The activity counts as over when the data field has been silent for this long. A short loss of connection is bridged; a longer one ends the sport phase early."
                    )
                ) {
                    Toggle("Move to Recovery Phase", isOn: $state.automation.moveToRecoveryAtEnd)

                    Stepper(
                        value: $state.automation.endTimeoutMinutes,
                        in: SportAutomationLogic.timeoutRange,
                        step: 1
                    ) {
                        Text("Silent for \(state.automation.endTimeoutMinutes) min")
                    }
                }
                .listRowBackground(Color.chart)

                Section(
                    footer: Text(
                        "The automation never replaces an override that is already running, and it does not start a profile again that you stopped during the same activity."
                    )
                ) {
                    Toggle("Notify Me", isOn: $state.automation.notify)

                    HStack {
                        Text("Last Signal From Data Field")
                        Spacer()
                        if let last = state.lastGarminSignal {
                            Text(last, format: .dateTime.day().month().hour().minute())
                                .foregroundStyle(Color.secondary)
                        } else {
                            Text("Never").foregroundStyle(Color.secondary)
                        }
                    }
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Apple Watch and Other Devices"),
                    footer: Text(
                        "In the Shortcuts app, create an automation such as \"When I start a workout on Apple Watch\" and add the Trio action \"Start a sport profile\". Use \"Next sport profile phase\" for when the workout ends."
                    )
                ) {
                    EmptyView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Automation")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: state.automation) { _, _ in
                state.saveAutomation()
            }
            .onAppear {
                state.reloadAutomation()
            }
        }
    }
}
