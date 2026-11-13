import AppKit
import AVFoundation
import Combine
import EventKit
import PerchUI
import Speech
import SwiftUI
import UserNotifications

/// The settings adapter only asks for access from an explicit button press.
@MainActor
final class SettingsPermissionAccess: PermissionAccess {
    private let services: Services
    private let eventStore = EKEventStore()
    init(services: Services) { self.services = services }

    func read(_ feature: PermissionFeature) async -> PermissionReading {
        switch feature {
        case .calendar:
            services.calendar.refresh()
            return Self.eventState(EKEventStore.authorizationStatus(for: .event))
        case .reminders: return Self.eventState(EKEventStore.authorizationStatus(for: .reminder))
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else {
                return PermissionReading(
                    .unavailable, detail: AppL10n.text("Notification access requires the installed Perch app."))
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined: return PermissionReading(.notDetermined)
            case .denied: return PermissionReading(.denied)
            case .authorized:
                guard settings.alertSetting == .enabled else {
                    return PermissionReading(
                        .limited,
                        detail: AppL10n.text(
                            "Permission is granted, but notification alerts are disabled in System Settings."))
                }
                return PermissionReading(.allowed)
            case .provisional:
                return PermissionReading(
                    .limited,
                    detail: AppL10n.text("Full notification alerts are not authorized. Review notification settings."))
            @unknown default: return PermissionReading(.unavailable)
            }
        case .speech:
            let state: PermissionState
            switch SFSpeechRecognizer.authorizationStatus() {
            case .notDetermined: state = .notDetermined
            case .authorized: state = .allowed
            case .denied: state = .denied
            case .restricted: state = .restricted
            @unknown default: state = .unavailable
            }
            guard state == .allowed else { return PermissionReading(state) }
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
                return PermissionReading(
                    .unavailable,
                    detail: AppL10n.text("Speech recognition is not currently available for this language."))
            }
            guard recognizer.supportsOnDeviceRecognition else {
                return PermissionReading(
                    .unavailable,
                    detail:
                        AppL10n.text(
                            "Install this language under System Settings › Keyboard › Dictation. Perch requires on-device recognition."
                        )
                )
            }
            return PermissionReading(.allowed)
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: return PermissionReading(.notDetermined)
            case .authorized: return PermissionReading(.allowed)
            case .denied: return PermissionReading(.denied)
            case .restricted: return PermissionReading(.restricted)
            @unknown default: return PermissionReading(.unavailable)
            }
        }
    }

    static func eventState(_ state: EKAuthorizationStatus) -> PermissionReading {
        switch state {
        case .notDetermined: PermissionReading(.notDetermined)
        case .fullAccess: PermissionReading(.allowed)
        case .writeOnly:
            PermissionReading(.limited, detail: AppL10n.text("Full access is required to read existing items."))
        case .denied: PermissionReading(.denied)
        case .restricted: PermissionReading(.restricted)
        @unknown default: PermissionReading(.unavailable)
        }
    }

    func request(_ feature: PermissionFeature) async throws {
        switch feature {
        case .calendar: await services.calendar.requestAccess()
        case .notifications: await services.reminders.requestAuthorization()
        case .speech:
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .reminders: _ = try await eventStore.requestFullAccessToReminders()
        }
    }
}

@MainActor
final class PermissionPanelModel: ObservableObject {
    @Published private(set) var readings: [PermissionFeature: PermissionReading] = [:]
    @Published private(set) var requesting: PermissionFeature?
    @Published private(set) var errors: [PermissionFeature: String] = [:]
    private let workflow: PermissionWorkflow

    init(access: any PermissionAccess) { workflow = PermissionWorkflow(access: access) }
    func refresh() async {
        await workflow.refresh()
        readings = workflow.readings
    }
    func request(_ feature: PermissionFeature) async {
        guard requesting == nil else { return }
        requesting = feature
        await workflow.request(feature)
        readings = workflow.readings
        errors = workflow.errors
        requesting = nil
    }
}

struct PermissionPanel: View {
    @StateObject private var model: PermissionPanelModel
    let features: [PermissionFeature]
    @State private var settingsError: String?

    init(services: Services, features: [PermissionFeature] = PermissionFeature.allCases) {
        _model = StateObject(wrappedValue: PermissionPanelModel(access: SettingsPermissionAccess(services: services)))
        self.features = features
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.cardPadding) {
            ForEach(features) { feature in
                row(feature)
                if feature != features.last { Divider() }
            }
            if let settingsError { Text(settingsError).font(Theme.meta).foregroundStyle(Theme.danger) }
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await model.refresh() }
        }
    }

    private func row(_ feature: PermissionFeature) -> some View {
        let reading = model.readings[feature] ?? PermissionReading(.checking)
        return VStack(alignment: .leading, spacing: Theme.gutter) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(feature.title).font(Theme.title)
                    Spacer(minLength: Theme.gutter)
                    status(reading.state)
                    action(feature, reading.state)
                }
                VStack(alignment: .leading, spacing: Theme.gutter) {
                    Text(feature.title).font(Theme.title)
                    HStack {
                        status(reading.state); Spacer(); action(feature, reading.state)
                    }
                }
            }
            Text(reading.detail ?? feature.detail).font(Theme.meta).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if reading.state == .restricted {
                Text("This access is managed by macOS or your administrator. It may not be changeable here.")
                    .font(Theme.meta).foregroundStyle(Theme.secondary)
            }
            if let error = model.errors[feature] { Text(error).font(Theme.meta).foregroundStyle(Theme.danger) }
        }
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permission-row.\(feature.rawValue)")
    }

    private func status(_ state: PermissionState) -> some View {
        StatusLabel(title: state.title, tone: state == .allowed ? .success : state == .checking ? .info : .warning)
    }

    @ViewBuilder private func action(_ feature: PermissionFeature, _ state: PermissionState) -> some View {
        if state == .notDetermined {
            Button(AppL10n.text(model.requesting == feature ? "Requesting…" : "Allow")) {
                Task { await model.request(feature) }
            }
            .buttonStyle(PillStyle(disabledReason: "Wait for the current permission request."))
            .disabled(model.requesting != nil)
            .accessibilityLabel(AppL10n.format("Allow %@", feature.title))
        } else if state != .checking {
            Button("Settings…") {
                if !NSWorkspace.shared.open(feature.settingsURL) {
                    settingsError = AppL10n.format("Open System Settings manually and select %@.", feature.title)
                }
            }
            .buttonStyle(PillStyle())
            .accessibilityLabel(AppL10n.format("Open %@ settings", feature.title))
        }
    }
}
