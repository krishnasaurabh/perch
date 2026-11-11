import Foundation

/// Permission state is queried after an attempt; completing a request never implies consent.
public enum PermissionState: String, CaseIterable, Sendable {
    case checking, notDetermined, allowed, denied, restricted, limited, unavailable, revoked

    public var title: String {
        switch self {
        case .checking: "Checking"
        case .notDetermined: "Not requested"
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .limited: "Limited access"
        case .unavailable: "Unavailable"
        case .revoked: "Revoked"
        }
    }
}

public enum PermissionFeature: String, CaseIterable, Identifiable, Sendable {
    case calendar, notifications, speech, microphone, reminders
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        case .speech: "Speech Recognition"
        case .microphone: "Microphone"
        case .reminders: "Apple Reminders"
        }
    }
    public var detail: String {
        switch self {
        case .calendar: "Show events beside your tasks. Perch only reads your calendars."
        case .notifications:
            "Allow reminder and timer alerts. Delivery also depends on macOS notification and Focus settings."
        case .speech: "Voice entry needs Speech Recognition, Microphone access and an available on-device language."
        case .microphone: "Voice entry cannot record without microphone access."
        case .reminders:
            "Access alone does not enable sync. Turn on mirroring in Settings; cross-device delivery depends on your Reminders account."
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
            errors[feature] = "The request could not be completed. Try again in System Settings."
        }
        await refresh()
    }
}
