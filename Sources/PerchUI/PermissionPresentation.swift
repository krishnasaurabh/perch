import Foundation

/// Permission state is queried after an attempt; completing a request never implies consent.
public enum PermissionState: String, CaseIterable, Sendable {
    case checking, notDetermined, allowed, denied, restricted, limited, unavailable, revoked

    public var title: String {
        switch self {
        case .checking: PerchL10n.text("Checking")
        case .notDetermined: PerchL10n.text("Not requested")
        case .allowed: PerchL10n.text("Allowed")
        case .denied: PerchL10n.text("Denied")
        case .restricted: PerchL10n.text("Restricted")
        case .limited: PerchL10n.text("Limited access")
        case .unavailable: PerchL10n.text("Unavailable")
        case .revoked: PerchL10n.text("Revoked")
        }
    }
}

public enum PermissionFeature: String, CaseIterable, Identifiable, Sendable {
    case calendar, notifications, speech, microphone, reminders
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .calendar: PerchL10n.text("Calendar")
        case .notifications: PerchL10n.text("Notifications")
        case .speech: PerchL10n.text("Speech Recognition")
        case .microphone: PerchL10n.text("Microphone")
        case .reminders: PerchL10n.text("Apple Reminders")
        }
    }
    public var detail: String {
        switch self {
        case .calendar: PerchL10n.text("Show events beside your tasks. Perch only reads your calendars.")
        case .notifications:
            PerchL10n.text(
                "Allow reminder and timer alerts. Delivery also depends on macOS notification and Focus settings.")
        case .speech:
            PerchL10n.text(
                "Voice entry needs Speech Recognition, Microphone access and an available on-device language.")
        case .microphone: PerchL10n.text("Voice entry cannot record without microphone access.")
        case .reminders:
            PerchL10n.text(
                "Access alone does not enable sync. Turn on mirroring in Settings; cross-device delivery depends on your Reminders account."
            )
        }
    }
    public var settingsURL: URL {
        let anchor: String
        switch self {
        case .calendar: anchor = "com.apple.preference.security?Privacy_Calendars"
        case .notifications: anchor = "com.apple.preference.notifications"
        case .speech: anchor = "com.apple.preference.security?Privacy_SpeechRecognition"
        case .microphone: anchor = "com.apple.preference.security?Privacy_Microphone"
        case .reminders: anchor = "com.apple.preference.security?Privacy_Reminders"
        }
        return URL(string: "x-apple.systempreferences:" + anchor)!
    }
}

public struct PermissionReading: Equatable, Sendable {
    public var state: PermissionState
    public var detail: String?
    public init(_ state: PermissionState, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }
}

@MainActor
public protocol PermissionAccess: AnyObject {
    func read(_ feature: PermissionFeature) async -> PermissionReading
    func request(_ feature: PermissionFeature) async throws
}

/// UI-independent workflow, exercised with fakes without opening system prompts.
@MainActor
public final class PermissionWorkflow {
    public private(set) var readings: [PermissionFeature: PermissionReading] = [:]
    public private(set) var requesting: PermissionFeature?
    public private(set) var errors: [PermissionFeature: String] = [:]
    private var previouslyAllowed: Set<PermissionFeature> = []
    private var generation = 0
    private let access: any PermissionAccess

    public init(access: any PermissionAccess) { self.access = access }

    public func refresh() async {
        generation += 1
        let version = generation
        var next: [PermissionFeature: PermissionReading] = [:]
        for feature in PermissionFeature.allCases { next[feature] = await access.read(feature) }
        guard version == generation else { return }
        for feature in PermissionFeature.allCases {
            guard var reading = next[feature] else { continue }
            if reading.state == .allowed { previouslyAllowed.insert(feature) }
            if reading.state == .denied && previouslyAllowed.contains(feature) { reading.state = .revoked }
            next[feature] = reading
        }
        readings = next
    }

    public func request(_ feature: PermissionFeature) async {
        guard requesting == nil, readings[feature]?.state == .notDetermined else { return }
        generation += 1
        requesting = feature
        errors[feature] = nil
        defer { requesting = nil }
        do { try await access.request(feature) } catch {
            errors[feature] = PerchL10n.text("The request could not be completed. Try again in System Settings.")
        }
        await refresh()
    }
}
