import SwiftUI
import Swinject

extension SportProfiles {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @State private var draft: SportProfile?
        @State private var profileToStart: SportProfile?

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                if let run = state.run {
                    runningSection(run)
                }

                Section(
                    header: Text("Sport Profiles"),
                    footer: Text(
                        "A sport profile runs several adjustments one after another: before, during and after sport. Each phase is an override. Setting or cancelling an override yourself ends the profile."
                    )
                ) {
                    if state.profiles.isEmpty {
                        Text("No sport profiles yet. Add one with the plus button.")
                            .foregroundStyle(Color.secondary)
                    }
                    ForEach(state.profiles) { profile in
                        profileRow(profile)
                    }
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Sport Profiles")
            .navigationBarTitleDisplayMode(.automatic)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu(content: {
                        ForEach(state.templates) { template in
                            Button(template.name) {
                                draft = state.draft(from: template)
                            }
                        }
                    }, label: {
                        Image(systemName: "plus")
                    })
                }
            }
            .sheet(item: $draft) { profile in
                SportProfileEditor(
                    profile: profile,
                    units: state.units,
                    onSave: { edited in
                        if state.save(edited) {
                            draft = nil
                        }
                    },
                    onCancel: { draft = nil }
                )
            }
            .confirmationDialog(
                Text("Start Sport Profile"),
                isPresented: Binding(
                    get: { profileToStart != nil },
                    set: { if !$0 { profileToStart = nil } }
                ),
                titleVisibility: .visible,
                actions: {
                    if let profile = profileToStart {
                        Button("Start \(profile.name)") {
                            state.start(profile)
                            profileToStart = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { profileToStart = nil }
                },
                message: {
                    Text("The first phase starts now and replaces any override that is running.")
                }
            )
            .alert(
                Text("Sport Profiles"),
                isPresented: $state.showError,
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(state.errorMessage ?? "") }
            )
        }

        // MARK: - Running profile

        private func runningSection(_ run: SportProfileRun) -> some View {
            Section(header: Text("Running")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.profileName).font(.headline)
                    if let phase = state.runningPhase {
                        Text(
                            "Phase \(run.phaseIndex + 1) of \(state.runningPhaseCount): \(phase.kind.localizedName)"
                        )
                        Text(state.summary(of: phase))
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("Ends at")
                        Text(run.phaseEndsAt, style: .time)
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                }

                Button(action: { state.nextPhase() }, label: {
                    Label("Next Phase", systemImage: "forward.end")
                })
                    .disabled(state.isBusy)

                Button(action: { state.extend() }, label: {
                    Label("Extend by 15 min", systemImage: "plus.circle")
                })
                    .disabled(state.isBusy)

                Button(role: .destructive, action: { state.stop() }, label: {
                    Label("Stop Sport Profile", systemImage: "stop.circle")
                })
                    .disabled(state.isBusy)
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - Rows

        private func profileRow(_ profile: SportProfile) -> some View {
            Button(action: {
                if !state.isBusy {
                    profileToStart = profile
                }
            }, label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).foregroundStyle(Color.primary)
                    ForEach(profile.phases) { phase in
                        Text("\(phase.kind.localizedName): \(state.summary(of: phase))")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                    }
                }
            })
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive, action: { state.delete(profile) }, label: {
                        Label("Delete", systemImage: "trash")
                    })
                    Button(action: { draft = profile }, label: {
                        Label("Edit", systemImage: "pencil")
                    })
                        .tint(.orange)
                }
        }
    }

    // MARK: - Editor

    struct SportProfileEditor: View {
        @State var profile: SportProfile
        let units: GlucoseUnits
        let onSave: (SportProfile) -> Void
        let onCancel: () -> Void

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            NavigationStack {
                Form {
                    Section(header: Text("Name")) {
                        TextField("Profile name", text: $profile.name)
                    }
                    .listRowBackground(Color.chart)

                    ForEach($profile.phases) { $phase in
                        Section(header: Text(phase.kind.localizedName)) {
                            Stepper(
                                value: $phase.durationMinutes,
                                in: SportProfileLogic.durationRange,
                                step: 5
                            ) {
                                Text("Duration: \(phase.durationMinutes) min")
                            }

                            Stepper(
                                value: $phase.percentage,
                                in: SportProfileLogic.percentageRange,
                                step: 5
                            ) {
                                Text("Insulin") + Text(verbatim: ": \(Int(phase.percentage)) %")
                            }

                            Toggle(
                                "Change Glucose Target",
                                isOn: Binding(
                                    get: { phase.target != nil },
                                    set: { phase.target = $0 ? 120 : nil }
                                )
                            )

                            if let target = phase.target {
                                Stepper(
                                    value: Binding(
                                        get: { phase.target ?? target },
                                        set: { phase.target = $0 }
                                    ),
                                    in: SportProfileLogic.targetRange,
                                    step: 5
                                ) {
                                    Text("Target: \(target.formatted(withUnits: units))")
                                }
                            }

                            Toggle("Disable SMBs", isOn: $phase.smbIsOff)
                        }
                        .listRowBackground(Color.chart)
                    }

                    Section(
                        footer: Text(
                            "Sport profiles can only reduce insulin delivery. The values of the templates are starting points; adjust them to your own experience."
                        )
                    ) {
                        EmptyView()
                    }
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle("Sport Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { onCancel() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Save") { onSave(profile) }
                            .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}
