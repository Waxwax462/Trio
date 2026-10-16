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
                    header: Text("Workout Temp Targets"),
                    footer: Text(
                        "Trio can read new completed workouts from Apple Health and apply the selected Temp Target preset using its saved duration. Applying a workout rule replaces any currently active Temp Target. Workouts are usually available after Apple Fitness saves them, so the target may start after the activity. Health access can be managed in Settings > Health > Data Access & Devices."
                    )
                ) {
                    Toggle(
                        "Apply Temp Targets From Workouts",
                        isOn: $state.activityTempTargetAutomationEnabled
                    ).disabled(state.isUpdatingActivityAutomation)

                    if let error = state.activityAutomationError {
                        Text(error).foregroundStyle(.red)
                    }

                    if state.activityTempTargetAutomationEnabled {
                        if state.tempTargetPresets.isEmpty {
                            Text("Create Temp Target presets in Adjustments before assigning workout rules.")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(AppleHealthWorkoutActivity.common) { activity in
                            Picker(
                                activity.title,
                                selection: Binding(
                                    get: { state.activityTempTargetRules[activity.id] ?? "" },
                                    set: { state.setTempTargetPreset($0, for: activity) }
                                )
                            ) {
                                Text("No Preset").tag("")
                                ForEach(state.tempTargetPresets, id: \.objectID) { preset in
                                    Text(preset.name ?? String(localized: "Temp Target"))
                                        .tag(preset.id?.uuidString ?? "")
                                }
                                if let selectedID = state.activityTempTargetRules[activity.id],
                                   !state.tempTargetPresets.contains(where: { $0.id?.uuidString == selectedID })
                                {
                                    Text("Preset unavailable").tag(selectedID)
                                }
                            }
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
