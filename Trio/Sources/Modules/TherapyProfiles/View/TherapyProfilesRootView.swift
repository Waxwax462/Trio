import SwiftUI
import Swinject

extension TherapyProfiles {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @State private var showCreateSheet = false
        @State private var newName: String = ""
        @State private var newSourceID: String = ""
        @State private var newPercentage: Double = 100
        @State private var profileToActivate: TherapyProfile?
        @State private var profileToRename: TherapyProfile?
        @State private var renameText: String = ""

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    header: Text("Therapy Profiles"),
                    footer: Text(
                        "A therapy profile is a complete set of basal rates, insulin sensitivities, carb ratios and glucose targets. Changes you make in the editors always apply to the active profile."
                    )
                ) {
                    ForEach(state.profiles) { profile in
                        profileRow(profile)
                    }
                }
                .listRowBackground(Color.chart)

                if state.isSwitching {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Switching profile…").padding(.leading, 8)
                        }
                    }
                    .listRowBackground(Color.chart)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Therapy Profiles")
            .navigationBarTitleDisplayMode(.automatic)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        newName = ""
                        newSourceID = state.activeProfileID ?? ""
                        newPercentage = 100
                        showCreateSheet = true
                    }, label: {
                        Image(systemName: "plus")
                    })
                }
            }
            .sheet(isPresented: $showCreateSheet) { createSheet }
            .sheet(item: $profileToActivate) { profile in activationSheet(profile) }
            .sheet(item: $profileToRename) { profile in renameSheet(profile) }
            .alert(
                Text("Therapy Profiles"),
                isPresented: $state.showError,
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(state.errorMessage ?? "") }
            )
        }

        // MARK: - Rows

        private func profileRow(_ profile: TherapyProfile) -> some View {
            let isActive = profile.id == state.activeProfileID
            return Button(action: {
                if !isActive, !state.isSwitching {
                    profileToActivate = profile
                }
            }, label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name).foregroundStyle(Color.primary)
                        Text(summary(of: profile))
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    if isActive {
                        Text("Active")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.green)
                    }
                }
            })
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !isActive {
                        Button(role: .destructive, action: { state.delete(profile) }, label: {
                            Label("Delete", systemImage: "trash")
                        })
                    }
                    Button(action: {
                        renameText = profile.name
                        profileToRename = profile
                    }, label: {
                        Label("Rename", systemImage: "pencil")
                    })
                        .tint(.orange)
                }
        }

        private func summary(of profile: TherapyProfile) -> String {
            let total = rounded(TherapyProfileLogic.dailyBasal(profile.settings.basal), scale: 2, roundingMode: .plain)
            return String(
                localized: "Basal \(total.description) U/day",
                comment: "Therapy profile summary: total daily basal insulin"
            )
        }

        // MARK: - Sheets

        private var createSheet: some View {
            NavigationStack {
                Form {
                    Section(header: Text("Name")) {
                        TextField("Profile name", text: $newName)
                    }
                    .listRowBackground(Color.chart)

                    Section(
                        header: Text("Copy From"),
                        footer: Text(
                            "100% copies the settings unchanged. A lower value creates a profile that delivers less insulin: basal rates are reduced, insulin sensitivities and carb ratios are raised. Glucose targets are not changed."
                        )
                    ) {
                        Picker("Profile", selection: $newSourceID) {
                            ForEach(state.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        Stepper(value: $newPercentage, in: 50 ... 150, step: 5) {
                            Text("Insulin") + Text(verbatim: ": \(Int(newPercentage)) %")
                        }
                    }
                    .listRowBackground(Color.chart)
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle("New Therapy Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { showCreateSheet = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") {
                            let source: String? = newSourceID.isEmpty ? nil : newSourceID
                            if state.create(name: newName, basedOn: source, percentage: Decimal(Int(newPercentage))) {
                                showCreateSheet = false
                            }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }

        private func renameSheet(_ profile: TherapyProfile) -> some View {
            NavigationStack {
                Form {
                    Section(header: Text("Name")) {
                        TextField("Profile name", text: $renameText)
                    }
                    .listRowBackground(Color.chart)
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle("Rename Therapy Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { profileToRename = nil }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") {
                            if state.rename(profile, to: renameText) {
                                profileToRename = nil
                            }
                        }
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }

        private func activationSheet(_ profile: TherapyProfile) -> some View {
            let differences = state.differences(to: profile)
            return NavigationStack {
                List {
                    if differences.isEmpty {
                        Section {
                            Text("This profile has the same settings as the active one.")
                        }
                        .listRowBackground(Color.chart)
                    } else {
                        ForEach(TherapySettingCategory.allCases, id: \.self) { category in
                            let rows = differences.filter { $0.category == category }
                            if !rows.isEmpty {
                                Section(header: Text(category.localizedName)) {
                                    ForEach(rows) { row in
                                        HStack {
                                            Text(TherapyProfileLogic.timeString(minutes: row.minutes))
                                            Spacer()
                                            Text(state.formatted(row.oldValue, category: category))
                                                .foregroundStyle(Color.secondary)
                                            Image(systemName: "arrow.right")
                                                .foregroundStyle(Color.secondary)
                                            Text(state.formatted(row.newValue, category: category))
                                        }
                                    }
                                }
                                .listRowBackground(Color.chart)
                            }
                        }
                    }

                    Section(
                        footer: Text(
                            "Basal rates are sent to the pump first. If the pump does not accept them, nothing is changed."
                        )
                    ) {
                        Button(action: {
                            profileToActivate = nil
                            state.activate(profile)
                        }, label: {
                            Text("Activate \(profile.name)")
                                .frame(maxWidth: .infinity, alignment: .center)
                        })
                    }
                    .listRowBackground(Color.chart)
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle("Review Changes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { profileToActivate = nil }
                    }
                }
            }
        }
    }
}
