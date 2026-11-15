import SwiftUI

extension SportProfiles {
    /// Settings for the "Sport today?" question.
    struct SportReminderView: View {
        @ObservedObject var state: StateModel

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            Form {
                Section(
                    footer: Text(
                        "Trio asks by notification whether you plan sport today. You can answer on the notification: start the preparation phase now, start it in an hour, or not today. After an answer there are no more questions that day. If you ignore a question, the next one comes at the next time."
                    )
                ) {
                    Toggle("Ask \"Sport Today?\"", isOn: $state.reminder.enabled)

                    Picker("Sport Profile", selection: $state.reminder.profileID) {
                        Text("None").tag(String?.none)
                        ForEach(state.profiles) { profile in
                            Text(profile.name).tag(String?.some(profile.id))
                        }
                    }
                }
                .listRowBackground(Color.chart)

                Section(header: Text("When")) {
                    Picker("Ask", selection: $state.reminder.mode) {
                        Text("At Fixed Times").tag(SportReminderMode.fixedTimes)
                        Text("Every Few Hours").tag(SportReminderMode.interval)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.chart)

                switch state.reminder.mode {
                case .fixedTimes:
                    fixedTimesSection
                case .interval:
                    intervalSection
                }

                if let planned = state.plannedStart {
                    Section(header: Text("Planned")) {
                        HStack {
                            Text("Sport Profile Starts At")
                            Spacer()
                            Text(planned, style: .time).foregroundStyle(Color.secondary)
                        }
                    }
                    .listRowBackground(Color.chart)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Daily Question")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: state.reminder) { _, _ in
                state.saveReminder()
            }
            .onAppear {
                state.reloadReminder()
            }
        }

        // MARK: - Fixed times

        private var fixedTimesSection: some View {
            Section(header: Text("Times")) {
                ForEach(state.reminder.times, id: \.self) { minutes in
                    HStack {
                        DatePicker(
                            "Time",
                            selection: Binding(
                                get: { date(fromMinutes: minutes) },
                                set: { state.setReminderTime(minutes, to: self.minutes(from: $0)) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()

                        Spacer()

                        Button(role: .destructive, action: { state.removeReminderTime(minutes) }, label: {
                            Image(systemName: "minus.circle")
                        })
                            .buttonStyle(.borderless)
                    }
                }

                if state.reminder.times.count < SportReminderLogic.maxTimesPerDay {
                    Button(action: { state.addReminderTime() }, label: {
                        Label("Add Time", systemImage: "plus.circle")
                    })
                }
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - Interval

        private var intervalSection: some View {
            Section(
                header: Text("Interval"),
                footer: Text("Questions today: \(SportReminderLogic.minutesOfDay(state.reminder).count)")
            ) {
                Stepper(value: $state.reminder.intervalHours, in: SportReminderLogic.intervalRange, step: 1) {
                    Text("Every \(state.reminder.intervalHours) h")
                }

                DatePicker(
                    "From",
                    selection: Binding(
                        get: { date(fromMinutes: state.reminder.windowStart) },
                        set: { state.reminder.windowStart = minutes(from: $0) }
                    ),
                    displayedComponents: .hourAndMinute
                )

                DatePicker(
                    "Until",
                    selection: Binding(
                        get: { date(fromMinutes: state.reminder.windowEnd) },
                        set: { state.reminder.windowEnd = minutes(from: $0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - Helpers

        private func date(fromMinutes minutes: Int) -> Date {
            let start = Calendar.current.startOfDay(for: Date())
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: start) ?? start
        }

        private func minutes(from date: Date) -> Int {
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            return (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
    }
}
