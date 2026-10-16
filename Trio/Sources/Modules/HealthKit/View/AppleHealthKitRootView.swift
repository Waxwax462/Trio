import SwiftUI
import Swinject

extension AppleHealthKit {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var booleanPlaceholder: Bool = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.useAppleHealth,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Connect to Apple Health")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Connect to Apple Health"),
                    miniHint: String(localized: "Allow Trio to read from and write to Apple Health."),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text("This allows Trio to read from and write to Apple Health.")
                        Text("Warning: You must also give permissions in iOS System Settings for the Health app.").bold()
                    },
                    headerText: String(localized: "Apple Health Integration")
                )

                if !state.needShowInformationTextForSetPermissions {
                    Section {
                        VStack {
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill")
                                Text("Give Apple Health Write Permissions")
                            }.padding(.bottom)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("1. Open the Settings app on your iOS device.")
                                Text(
                                    "2. Scroll down or type \"Health\" in the settings search bar and select the \"Health\" app."
                                )
                                Text("3. Tap on \"Data Access & Devices\".")
                                Text("4. Find and select \"Trio\" from the list of apps.")
                                Text("5. Ensure that the \"Write Data\" option is enabled for the desired health metrics.")
                            }.font(.footnote)
                        }
                        .padding(.vertical)
                        .foregroundColor(Color.secondary)
                    }.listRowBackground(Color.chart)
                }

                Section(
                    header: Text("Workout Recovery"),
                    footer: Text(
                        "When a completed workout of any activity type is saved to Apple Health, Trio can apply a temporary basal-rate reduction for the selected duration. This replaces active Overrides and Temp Targets. Initial values are 80% for 120 minutes; they are examples, not a therapy recommendation. Only enable automation if the settings match your personal treatment plan. At 100%, no recovery Override is applied. Health access can be managed in Settings > Health > Data Access & Devices."
                    )
                ) {
                    Toggle(
                        "Apply Recovery Override After Workouts",
                        isOn: $state.workoutRecoveryAutomationEnabled
                    ).disabled(state.isUpdatingWorkoutRecoveryAutomation)

                    if let error = state.workoutRecoveryAutomationError {
                        Text(error).foregroundStyle(.red)
                    }

                    Picker("Basal Rate During Recovery", selection: $state.workoutRecoveryBasalPercentage) {
                        ForEach(Array(stride(from: 40, through: 100, by: 5)), id: \.self) { percentage in
                            Text("\(percentage)%").tag(percentage)
                        }
                    }

                    Stepper(value: $state.workoutRecoveryDurationMinutes, in: 15...1440, step: 15) {
                        HStack {
                            Text("Recovery Duration")
                            Spacer()
                            Text("\(state.workoutRecoveryDurationMinutes) min")
                                .foregroundStyle(.secondary)
                        }
                    }
                }.listRowBackground(Color.chart)
            }
            .listSectionSpacing(sectionSpacing)
            .sheet(isPresented: $shouldDisplayHint) {
                SettingInputHintView(
                    hintDetent: $hintDetent,
                    shouldDisplayHint: $shouldDisplayHint,
                    hintLabel: hintLabel ?? "",
                    hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                    sheetTitle: String(localized: "Help", comment: "Help sheet title")
                )
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.automatic)
        }
    }
}
