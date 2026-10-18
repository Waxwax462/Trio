//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import LoopKitUI
import SwiftUI
import Swinject

struct NotificationsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel
    @State var notificationsDisabled = false
    @State var showAlert = false
    @State private var showSnoozeSheet = false
    @State private var shouldDisplayHint: Bool = false
    @State var hintDetent = PresentationDetent.large
    @State var selectedVerboseHint: AnyView? = AnyView(
        VStack(alignment: .leading, spacing: 10) {
            Text("Notifications give you important Trio information without requiring you to open the app.")
            Text(
                "Keep notifications and Time Sensitive Notifications turned on in iOS Settings. On iOS 26, allow Alarms for Trio when prompted; audible nighttime alarms use AlarmKit to sound through Sleep Focus. On earlier iOS versions, Focus behavior depends on the alarm’s Override Silence & Focus Mode setting and your notification settings."
            )
        }
    )
    @State var hintLabel: String? = String(localized: "Manage iOS Preferences")
    @State var timeSensitiveNotificationsDisabled = false
    @State private var alarmKitAuthorized = false
    @State private var isStartingTestAlarm = false
    @State private var testAlarmMessage: String?

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section(
                header: Text("Mute Trio Alarms"),
                content: {
                    VStack {
                        Button {
                            showSnoozeSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "zzz").foregroundStyle(.tint)
                                Text("Snooze All Alarms").bold()
                            }
                            .font(.title3)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .buttonStyle(.bordered)
                    }.padding(.vertical)
                }
            ).listRowBackground(Color.chart)

            Section(
                header: Text("Manage iOS Preferences"),
                content: {
                    notificationsEnabledStatus
                    timeSensitiveNotificationsStatus
                    if #available(iOS 26, *) {
                        alarmKitAuthorizationStatus
                    }

                    manageNotifications
                }
            ).listRowBackground(Color.chart)

            if #available(iOS 26, *) {
                testAlarmSection.listRowBackground(Color.chart)
            }

            Section(
                header: Text("Notification Center"),
                content: {
                    Text("Glucose Alarms")
                        .navigationLink(to: .glucoseAlerts, from: self)

                    Text("Device Alarms")
                        .navigationLink(to: .deviceAlarms, from: self)

                    Text("Day & Night Windows")
                        .navigationLink(to: .alarmWindows, from: self)
                }
            ).listRowBackground(Color.chart)

            Section(
                header: Text("Other Notifications"),
                content: {
                    if #available(iOS 16.2, *) {
                        Text("Live Activity").navigationLink(to: .liveActivitySettings, from: self)
                    }

                    Text("Calendar Events").navigationLink(to: .calendarEventSettings, from: self)
                }
            ).listRowBackground(Color.chart)
        }
        .listSectionSpacing(sectionSpacing)
        .onAppear(perform: refreshAlarmKitAuthorization)
        .onReceive(
            Foundation.NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification),
            perform: { _ in refreshAlarmKitAuthorization() }
        )
        .onReceive(
            resolver.resolve(AlertPermissionsChecker.self)!.$notificationsDisabled,
            perform: {
                if notificationsDisabled != $0 {
                    notificationsDisabled = $0
                    if notificationsDisabled {
                        showAlert = true
                    }
                }
            }
        )
        .onReceive(
            resolver.resolve(AlertPermissionsChecker.self)!.$timeSensitiveNotificationsDisabled,
            perform: { timeSensitiveNotificationsDisabled = $0 }
        )
        .alert(
            isPresented: self.$showAlert,
            content: { self.notificationReminder() }
        )
        .sheet(isPresented: $shouldDisplayHint) {
            SettingInputHintView(
                hintDetent: $hintDetent,
                shouldDisplayHint: $shouldDisplayHint,
                hintLabel: hintLabel ?? "",
                hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                sheetTitle: String(localized: "Help", comment: "Help sheet title")
            )
        }
        .sheet(isPresented: $showSnoozeSheet) {
            SnoozeAlertsSheetView(resolver: resolver, isPresented: $showSnoozeSheet)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.automatic)
    }
}

extension NotificationsView {
    func notificationReminder() -> Alert {
        Alert(
            title: Text("\u{2757} Notifications are Required"),
            message: Text(
                "Please authorize notifications by tapping 'Open iOS Settings' > 'Notifications' and enable 'Allow Notifications' for 'Notification Center' and 'Banners' Alerts."
            ),
            dismissButton: .default(Text("Ok"))
        )
    }

    @ViewBuilder private func onOff(_ val: Bool) -> some View {
        if val {
            Text(String(localized: "On", comment: "Notification Setting Status is On"))
        } else {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.critical)
                Text(String(localized: "Off", comment: "Notification Setting Status is Off"))
            }
        }
    }

    private var manageNotifications: some View {
        Button(action: { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }) {
            HStack {
                Text(String(localized: "Open iOS Settings", comment: "Manage Permissions in Settings button text"))
                Spacer()
                Image(systemName: "chevron.right").foregroundColor(.gray).font(.footnote)
            }
        }
        .accentColor(.primary)
    }

    private var notificationsEnabledStatus: some View {
        HStack {
            Text(String(localized: "Notifications", comment: "Notifications Status text"))
            Spacer()
            onOff(!notificationsDisabled)
        }
    }

    private var timeSensitiveNotificationsStatus: some View {
        HStack {
            Text("Time Sensitive Notifications")
            Spacer()
            onOff(!timeSensitiveNotificationsDisabled)
        }
    }

    @ViewBuilder private var alarmKitAuthorizationStatus: some View {
        HStack {
            Text("AlarmKit (iOS 26)")
            Spacer()
            onOff(alarmKitAuthorized)
        }
    }

    private var testAlarmSection: some View {
        Section(
            header: Text("Test Alarm"),
            content: {
                Button(action: startTestAlarm) {
                    HStack {
                        Image(systemName: "bell.badge").foregroundStyle(.tint)
                        Text(isStartingTestAlarm ? "Starting Test Alarm…" : "Start Test Alarm").bold()
                        Spacer()
                        if isStartingTestAlarm {
                            ProgressView()
                        }
                    }
                }
                .disabled(isStartingTestAlarm)

                Text(
                    testAlarmMessage
                        ?? "Tests the AlarmKit night-alarm path with your configured night sound. Stop it on the alarm screen."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        )
    }

    private func startTestAlarm() {
        guard !isStartingTestAlarm else { return }
        isStartingTestAlarm = true
        testAlarmMessage = nil
        Task { @MainActor in
            defer { isStartingTestAlarm = false }
            do {
                try await resolver.resolve(TrioAlertManager.self)!.scheduleTestAlarm()
                testAlarmMessage = String(
                    localized: "Test alarm scheduled. It should ring in a few seconds; stop it on the alarm screen."
                )
            } catch {
                testAlarmMessage = error.localizedDescription
            }
        }
    }

    private func refreshAlarmKitAuthorization() {
        guard #available(iOS 26, *) else { return }
        Task { @MainActor in
            alarmKitAuthorized = CriticalAlertAlarmScheduler.systemAlarmAuthorizationGranted
        }
    }
}
